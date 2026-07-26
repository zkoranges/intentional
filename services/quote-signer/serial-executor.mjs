// Serializes an asynchronous critical section inside the single signer
// process. The quote server runs as exactly one systemd process, so holding
// this lock across chain reads makes the sweep -> sign -> reserve sequence
// atomic with respect to every other HTTP request handled by that process.
export class SerialExecutor {
  #tail = Promise.resolve();

  run(task) {
    if (typeof task !== "function") throw new TypeError("task must be a function");

    const result = this.#tail.then(task, task);
    this.#tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }
}
