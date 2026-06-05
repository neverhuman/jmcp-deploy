# Jankurai Adapter Standard

JMCP Deploy owns split-family orchestration, local launch, health checks,
Jeryu/GitHub wiring, and release receipts. It must not embed product code or
secrets.

GitHub CI uses offline health checks. Local promotion gates may add
`--require-jeryu` to prove the local Jeryu server is reachable.

