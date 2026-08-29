# terminator docs

| | |
|---|---|
| [roadmap/](roadmap/) | What is planned, what shipped, and what measurement killed. |
| [benchmarking.md](benchmarking.md) | How `zig build bench` works and how to add a corpus. |

For building, testing and sending a patch, see
[CONTRIBUTING.md](../CONTRIBUTING.md). For what the terminal does and does not
do yet, see the [README](../README.md).

## The one rule

Performance claims here carry a number or they are labelled as guesses.
The roadmap was written once from reading the source, and the largest
bottleneck in the program was not on it — see
[sprint 0](roadmap/completed/sprint-0-benchmarks.md) for how that went.
