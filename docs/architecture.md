# JMCP Deploy Architecture

`jmcp-deploy` owns split-family orchestration for `jmcp-core`, `jmcp-web`,
`jmcp-talk`, and `jmcp-deploy`.

The repo wires local launch, health, smoke checks, Jeryu control scripts, and
GitHub mirror helpers. It does not own product runtime behavior.
