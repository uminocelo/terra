defmodule Terra.Runtime.SignalHandler do
  @moduledoc """
  Forwards `SIGWINCH` to a runtime process.

  `:os.set_signal(:sigwinch, :handle)` only tells the runtime to handle the signal;
  delivery goes through the `:erl_signal_server` event manager. This handler is
  added with the runtime pid as its state and sends it `:terra_sigwinch` on every
  window change, so the runtime can re-query the size and push `{:resize, w, h}`.

  Installing it is best effort: on a platform without `:sigwinch` the runtime keeps
  working and `Terra.Runtime.resize/1-3` stays available as an explicit path.
  """

  @behaviour :gen_event

  @impl true
  def init(target) when is_pid(target), do: {:ok, target}

  @impl true
  def handle_event(:sigwinch, target) do
    send(target, :terra_sigwinch)
    {:ok, target}
  end

  def handle_event(_signal, target), do: {:ok, target}

  @impl true
  def handle_call(_request, target), do: {:ok, :ok, target}

  @impl true
  def handle_info(_message, target), do: {:ok, target}

  @impl true
  def terminate(_reason, _target), do: :ok

  @impl true
  def code_change(_old_version, target, _extra), do: {:ok, target}
end
