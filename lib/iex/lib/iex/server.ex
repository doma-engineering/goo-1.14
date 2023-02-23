defmodule IEx.Server do
  @moduledoc """
  The IEx.Server.

  The server responsibilities include:

    * reading input from the group leader and writing to the group leader
    * sending messages to the evaluator
    * taking over the evaluator process when using `IEx.pry/0` or setting up breakpoints

  """

  @doc false
  defstruct parser_state: [],
            counter: 1,
            prefix: "iex",
            on_eof: :stop_evaluator,
            evaluator_options: [],
            expand_fun: nil

  @doc """
  Starts a new IEx server session.

  The accepted options are:

    * `:prefix` - the IEx prefix
    * `:env` - the `Macro.Env` used for the evaluator
    * `:binding` - an initial set of variables for the evaluator
    * `:on_eof` - if it should `:stop_evaluator` (default) or `:halt` the system

  """
  @doc since: "1.8.0"
  @spec run(keyword) :: :ok
  def run(opts) when is_list(opts) do
    IEx.Broker.register(self())
    run_without_registration(init_state(opts), opts, nil)
  end

  ## Private APIs

  # Starts IEx to run directly from the Erlang shell.
  #
  # The server is spawned only after the callback is done.
  #
  # If there is any takeover during the callback execution
  # we spawn a new server for it without waiting for its
  # conclusion.
  @doc false
  @spec run_from_shell(keyword, {module, atom, [any]}) :: :ok
  def run_from_shell(opts, {m, f, a}) do
    opts[:register] && IEx.Broker.register(self())
    Process.flag(:trap_exit, true)
    {pid, ref} = spawn_monitor(m, f, a)
    shell_loop(opts, pid, ref)
  end

  defp shell_loop(opts, pid, ref) do
    receive do
      {:take_over, take_pid, take_ref, take_location, take_whereami, take_opts} ->
        if take_over?(take_pid, take_ref, take_location, take_whereami, take_opts, 1) do
          run_without_registration(init_state(opts), take_opts, nil)
        else
          shell_loop(opts, pid, ref)
        end

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        run_without_registration(init_state(opts), opts, nil)

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    end
  end

  # Since we want to register only once, this function is the
  # reentrant point for starting a new shell (instead of run/run_from_shell).
  defp run_without_registration(state, opts, input) do
    Process.flag(:trap_exit, true)
    Process.link(Process.group_leader())

    IO.puts(
      "Interactive Elixir (#{System.version()}) - press Ctrl+C to exit (type h() ENTER for help)"
    )

    evaluator = start_evaluator(state.counter, Keyword.merge(state.evaluator_options, opts))
    loop(state, evaluator, Process.monitor(evaluator), input)
  end

  # Starts an evaluator using the provided options.
  # Made public but undocumented for testing.
  @doc false
  def start_evaluator(counter, opts) do
    args = [:ack, self(), Process.group_leader(), counter, opts]
    evaluator = opts[:evaluator] || :proc_lib.start(IEx.Evaluator, :init, args)
    Process.put(:evaluator, evaluator)
    evaluator
  end

  ## Helpers

  defp stop_evaluator(evaluator, evaluator_ref) do
    Process.delete(:evaluator)
    Process.demonitor(evaluator_ref, [:flush])
    send(evaluator, {:done, self(), false})
    :ok
  end

  defp rerun(state, opts, evaluator, evaluator_ref, input) do
    IO.puts("")
    stop_evaluator(evaluator, evaluator_ref)
    state = reset_state(state)
    run_without_registration(state, opts, input)
  end

  defp loop(state, evaluator, evaluator_ref, input) do
    %{counter: counter, expand_fun: expand_fun, prefix: prefix, parser_state: parser} = state
    :io.setopts(expand_fun: expand_fun)
    input = input || io_get(prompt(prefix, counter), counter, parser)
    wait_input(state, evaluator, evaluator_ref, input)
  end

  defp wait_input(state, evaluator, evaluator_ref, input) do
    receive do
      {:io_reply, ^input, {:ok, code, parser_state}} ->
        :io.setopts(expand_fun: fn _ -> {:yes, [], []} end)
        send(evaluator, {:eval, self(), code, state.counter})
        wait_eval(%{state | parser_state: parser_state}, evaluator, evaluator_ref)

      {:io_reply, ^input, :eof} ->
        case state.on_eof do
          :halt -> System.halt(0)
          :stop_evaluator -> stop_evaluator(evaluator, evaluator_ref)
        end

      {:io_reply, ^input, {:error, kind, error, stacktrace}} ->
        banner = IEx.color(:eval_error, Exception.format_banner(kind, error, stacktrace))
        stackdata = Exception.format_stacktrace(stacktrace)
        IO.write(:stdio, [banner, ?\n, IEx.color(:stack_info, stackdata)])
        loop(%{state | parser_state: []}, evaluator, evaluator_ref, nil)

      # Triggered by pressing "i" as the job control switch
      {:io_reply, ^input, {:error, :interrupted}} ->
        io_error("** (EXIT) interrupted")
        loop(%{state | parser_state: []}, evaluator, evaluator_ref, nil)

      # Unknown IO message
      {:io_reply, ^input, msg} ->
        io_error("** (EXIT) unknown IO message: #{inspect(msg)}")
        loop(%{state | parser_state: []}, evaluator, evaluator_ref, nil)

      # Triggered when IO dies while waiting for input
      {:DOWN, ^input, _, _, _} ->
        stop_evaluator(evaluator, evaluator_ref)

      msg ->
        handle_take_over(msg, state, evaluator, evaluator_ref, input, fn state ->
          wait_input(state, evaluator, evaluator_ref, input)
        end)
    end
  end

  defp wait_eval(state, evaluator, evaluator_ref) do
    receive do
      {:evaled, ^evaluator, status} ->
        counter = if(status == :ok, do: state.counter + 1, else: state.counter)
        state = %{state | counter: counter}
        loop(state, evaluator, evaluator_ref, nil)

      msg ->
        handle_take_over(msg, state, evaluator, evaluator_ref, nil, fn state ->
          wait_eval(state, evaluator, evaluator_ref)
        end)
    end
  end

  defp wait_take_over(state, evaluator, evaluator_ref, input) do
    receive do
      msg ->
        handle_take_over(msg, state, evaluator, evaluator_ref, input, fn state ->
          wait_take_over(state, evaluator, evaluator_ref, input)
        end)
    end
  end

  # Take process.
  #
  # A take process may also happen if the evaluator dies,
  # then a new evaluator is created to replace the dead one.
  defp handle_take_over(
         {:take_over, take_pid, take_ref, take_location, take_whereami, take_opts},
         state,
         evaluator,
         evaluator_ref,
         input,
         callback
       ) do
    cond do
      evaluator == take_opts[:evaluator] ->
        IO.puts(IEx.color(:eval_interrupt, "Break reached: #{take_location}#{take_whereami}"))

        if take_over?(take_pid, take_ref, state.counter + 1, true) do
          # Since we are in process, also bump the counter
          state = reset_state(bump_counter(state))
          loop(state, evaluator, evaluator_ref, input)
        else
          callback.(state)
        end

      take_over?(take_pid, take_ref, take_location, take_whereami, take_opts, state.counter) ->
        rerun(state, take_opts, evaluator, evaluator_ref, input)

      true ->
        callback.(state)
    end
  end

  # User did ^G while the evaluator was busy or stuck
  defp handle_take_over(
         {:EXIT, _pid, :interrupt},
         state,
         evaluator,
         evaluator_ref,
         input,
         _callback
       ) do
    io_error("** (EXIT) interrupted")
    Process.exit(evaluator, :kill)
    rerun(state, [], evaluator, evaluator_ref, input)
  end

  defp handle_take_over(
         {:EXIT, pid, reason},
         state,
         evaluator,
         evaluator_ref,
         _input,
         callback
       ) do
    if pid == Process.group_leader() do
      stop_evaluator(evaluator, evaluator_ref)
      exit(reason)
    else
      callback.(state)
    end
  end

  defp handle_take_over({:respawn, evaluator}, state, evaluator, evaluator_ref, input, _callback) do
    rerun(bump_counter(state), [], evaluator, evaluator_ref, input)
  end

  defp handle_take_over(
         {:continue, evaluator, next?},
         state,
         evaluator,
         evaluator_ref,
         input,
         _callback
       ) do
    send(evaluator, {:done, self(), next?})
    wait_take_over(state, evaluator, evaluator_ref, input)
  end

  defp handle_take_over(
         {:DOWN, evaluator_ref, :process, evaluator, :normal},
         state,
         evaluator,
         evaluator_ref,
         input,
         _callback
       ) do
    rerun(state, [], evaluator, evaluator_ref, input)
  end

  defp handle_take_over(
         {:DOWN, evaluator_ref, :process, evaluator, reason},
         state,
         evaluator,
         evaluator_ref,
         input,
         _callback
       ) do
    try do
      io_error(
        "** (EXIT from #{inspect(evaluator)}) shell process exited with reason: " <>
          Exception.format_exit(reason)
      )
    catch
      type, detail ->
        io_error("** (IEx.Error) #{type} when printing EXIT message: #{inspect(detail)}")
    end

    rerun(state, [], evaluator, evaluator_ref, input)
  end

  defp handle_take_over(_, state, _evaluator, _evaluator_ref, _input, callback) do
    callback.(state)
  end

  defp take_over?(take_pid, take_ref, take_location, take_whereami, take_opts, counter) do
    evaluator = take_opts[:evaluator]
    message = "Request to pry #{inspect(evaluator)} at #{take_location}#{take_whereami}"
    interrupt = IEx.color(:eval_interrupt, "#{message}\nAllow? [Yn] ")
    take_over?(take_pid, take_ref, counter, yes?(IO.gets(:stdio, interrupt)))
  end

  defp take_over?(take_pid, take_ref, counter, response) when is_boolean(response) do
    case IEx.Broker.respond(take_pid, take_ref, counter, response) do
      :ok ->
        true

      {:error, :refused} ->
        false

      {:error, :already_accepted} ->
        io_error("** session was already accepted elsewhere")
        false
    end
  end

  defp yes?(string) do
    is_binary(string) and String.trim(string) in ["", "y", "Y", "yes", "YES", "Yes"]
  end

  ## State

  defp init_state(opts) do
    prefix = Keyword.get(opts, :prefix, "iex")
    on_eof = Keyword.get(opts, :on_eof, :stop_evaluator)
    gl = Process.group_leader()

    expand_fun =
      if node(gl) != node() do
        IEx.Autocomplete.remsh(node())
      else
        &IEx.Autocomplete.expand/1
      end

    %IEx.Server{
      prefix: prefix,
      on_eof: on_eof,
      expand_fun: expand_fun,
      evaluator_options: Keyword.take(opts, [:dot_iex_path])
    }
  end

  # For the state, reset only reset the parser state.
  # The counter will continue going up as the input process is shared.
  # The opts can also set "dot_iex_path" and the "evaluator" itself,
  # but those are not stored: they are temporary to whatever is rerunning.
  # Once the rerunning session restarts, we keep the same evaluator_options
  # and rollback to a new evaluator.
  defp reset_state(state) do
    %{state | parser_state: []}
  end

  defp bump_counter(state) do
    update_in(state.counter, &(&1 + 1))
  end

  ## IO

  defp io_get(prompt, counter, parser_state) do
    gl = Process.group_leader()
    ref = Process.monitor(gl)
    command = {:get_until, :unicode, prompt, __MODULE__, :__parse__, [{counter, parser_state}]}
    send(gl, {:io_request, self(), ref, command})
    ref
  end

  @doc false
  def __parse__(_, :eof, _parser_state), do: {:done, :eof, []}

  def __parse__([], chars, {counter, parser_state} = to_be_unused) do
    __parse__({counter, parser_state, IEx.Config.parser()}, chars, to_be_unused)
  end

  def __parse__({counter, parser_state, mfa}, chars, _unused) do
    {parser_module, parser_fun, args} = mfa
    args = [chars, [line: counter, file: "iex"], parser_state | args]

    case apply(parser_module, parser_fun, args) do
      {:ok, forms, parser_state} -> {:done, {:ok, forms, parser_state}, []}
      {:incomplete, parser_state} -> {:more, {counter, parser_state, mfa}}
    end
  catch
    kind, error ->
      {:done, {:error, kind, error, __STACKTRACE__}, []}
  end

  # If parsing fails, this might be a TokenMissingError which we treat in
  # a special way (to allow for continuation of an expression on the next
  # line in IEx).
  #
  # The first two clauses provide support for the break-trigger allowing to
  # break out from a pending incomplete expression. See
  # https://github.com/elixir-lang/elixir/issues/1089 for discussion.
  @break_trigger ~c"#iex:break\n"

  @op_tokens [:or_op, :and_op, :comp_op, :rel_op, :arrow_op, :in_op] ++
               [:three_op, :concat_op, :mult_op]

  @doc false
  def parse(input, opts, parser_state)

  def parse(input, opts, []), do: parse(input, opts, {[], :other})

  def parse(@break_trigger, opts, _parser_state) do
    :elixir_errors.parse_error(
      [line: opts[:line]],
      opts[:file],
      "incomplete expression",
      "",
      {~c"", Keyword.get(opts, :line, 1), Keyword.get(opts, :column, 1)}
    )
  end

  def parse(input, opts, {buffer, last_op}) do
    input = buffer ++ input
    file = Keyword.get(opts, :file, "nofile")
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)

    result =
      with {:ok, tokens} <- :elixir.string_to_tokens(input, line, column, file, opts),
           {:ok, adjusted_tokens} <- adjust_operator(tokens, line, column, file, opts, last_op),
           {:ok, forms} <- :elixir.tokens_to_quoted(adjusted_tokens, file, opts) do
        last_op =
          case forms do
            {:=, _, [_, _]} -> :match
            _ -> :other
          end

        {:ok, forms, last_op}
      end

    case result do
      {:ok, forms, last_op} ->
        {:ok, forms, {[], last_op}}

      {:error, {_, _, ""}} ->
        {:incomplete, {input, last_op}}

      {:error, {location, error, token}} ->
        :elixir_errors.parse_error(
          location,
          file,
          error,
          token,
          {input, line, column}
        )
    end
  end

  defp adjust_operator([{op_type, _, token} | _] = _tokens, line, column, _file, _opts, :match)
       when op_type in @op_tokens,
       do:
         {:error,
          {[line: line, column: column],
           "pipe shorthand is not allowed immediately after a match expression in IEx. To make it work, surround the whole pipeline with parentheses ",
           "'#{token}'"}}

  defp adjust_operator([{op_type, _, _} | _] = tokens, line, column, file, opts, _last_op)
       when op_type in @op_tokens do
    {:ok, prefix} = :elixir.string_to_tokens(~c"v(-1)", line, column, file, opts)
    {:ok, prefix ++ tokens}
  end

  defp adjust_operator(tokens, _line, _column, _file, _opts, _last_op), do: {:ok, tokens}

  defp prompt(prefix, counter) do
    prompt =
      if Node.alive?() do
        IEx.Config.alive_prompt()
      else
        IEx.Config.default_prompt()
      end
      |> String.replace("%counter", to_string(counter))
      |> String.replace("%prefix", to_string(prefix))
      |> String.replace("%node", to_string(node()))

    [prompt, " "]
  end

  defp io_error(result) do
    IO.puts(:stdio, IEx.color(:eval_error, result))
  end
end
