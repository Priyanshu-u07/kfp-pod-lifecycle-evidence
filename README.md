# Pod lifecycle failure: measured behaviour

Raw observations of what Kubeflow Pipelines' execution engine and Kubernetes actually
report when a task pod fails to start, fails at runtime, or is never created at all.

Every claim here was produced by running a deliberately broken workflow against a live
cluster and capturing the result. Nothing is inferred from reading source, and nothing is
taken from discussion threads.

## Environment

| | |
|---|---|
| Captured | 2026-08-09 to 2026-08-13 |
| Cluster | `kind`, single node, 4 allocatable CPU |
| Kubernetes | server v1.35.0 (client v1.34.1) |
| Argo Workflows | v4.0.4 (`quay.io/argoproj/workflow-controller:v4.0.4`) |
| Setup | bare Argo, **no KFP installed** (see Limitations) |

Captured across two sessions. The version block in every capture confirms the environment
was unchanged between them. Two of the findings below need elapsed time and cannot be
observed in a single sitting.

The Argo version matters: kubeflow/pipelines migrated to Argo 4.x in `2f6bcfcfb`
(2026-06-18), so message strings recorded against Argo 3.x may no longer match what the
engine emits.

## Scenarios

| File | Trigger | Reason produced |
|---|---|---|
| `1-imagepull.yaml` | image tag that does not exist | `ImagePullBackOff` |
| `2-unschedulable.yaml` | `cpu: 128` on a 4-CPU node | `Unschedulable` |
| `3-oomkilled.yaml` | allocate 500 MB against a 64 Mi limit | `OOMKilled` |
| `4-nonzero-exit.yaml` | `sys.exit(1)` | `Error` (exit code 1) |
| `5-configerror.yaml` | `secretKeyRef` to a Secret that does not exist | `CreateContainerConfigError` |
| `6-invalidimage.yaml` | malformed image reference | `InvalidImageName` |
| `7-recovery.yaml` | two 3-CPU steps in parallel on a 4-CPU node | `Unschedulable`, then recovery |
| *(quota, see below)* | `ResourceQuota` of `pods=0` | admission rejection, no pod created |
| `9-pvc.yaml` | PVC naming a storage class that does not exist | `Unschedulable` |

Scenario 8 has no workflow file because it reuses `1-imagepull.yaml`. It runs in its own
namespace with a quota that forbids pods outright, so pod creation is rejected at admission
and no pod is ever created:

```bash
kubectl create ns quota-test
kubectl create quota no-pods --hard=pods=0 -n quota-test
kubectl create -n quota-test -f 1-imagepull.yaml
./capture.sh <workflow-name> quota-test
```

Deleting the quota afterwards is what produced `timeline-3-quota-recovery.txt`.

## Findings

**1. Every reason reaches the node message, including `Unschedulable`.**
Argo prefixes the condition reason:
`Unschedulable: 0/1 nodes are available: 1 Insufficient cpu…`
No pod informer and no Event watch is needed to observe any of these; `status.nodes[].message`
carries them all. See `capture-2-unschedulable.txt`, which also shows the corresponding pod
condition `PodScheduled / False / Unschedulable`.

**2. Messages arrive in three shapes, and only one carries a reason as its prefix.**

```
waiting-state     <Reason>: <detail>              ImagePullBackOff: Back-off pulling image "…"
terminated-state  <container>: <Reason> (exit N)  main: OOMKilled (exit code 137)
admission         pods "<name>" is forbidden: …   pods "x" is forbidden: exceeded quota: …
```

A parser taking the token before the first colon yields `main` for the second form, which
is a container name, and `pods "x" is forbidden` for the third, which is not a reason at
all. Classification cannot be a single prefix rule.

**3. One reason, two opposite outcomes.**
A pod blocked on a nonexistent storage class and a pod merely waiting for CPU report
identically. In `capture-9-pvc.txt` both appear as adjacent events in the same capture:

```
FailedScheduling  repro-pvc-…            0/1 nodes are available: pod has unbound immediate
                                         PersistentVolumeClaims. not found
FailedScheduling  repro-unschedulable-…  0/1 nodes are available: 1 Insufficient cpu.
                                         no new claims to deallocate…
```

Both carry the pod condition `PodScheduled / False / Unschedulable`, both produce the event
reason `FailedScheduling`, and neither has any `containerStatuses`, so reading the pod object
does not separate them either. Their prospects are opposite: capacity frees on its own
(finding 7), while a storage class that does not exist never appears.

Terminality therefore cannot be resolved from the reason alone. The detail text after the
prefix is the discriminator.

**4. Only the node record sees an admission rejection.**
With a `ResourceQuota` of `pods=0` the API server refuses pod creation outright. There is no
pod, no pod condition, no container status, and no pod events, because no pod exists. The
only event in the namespace is Argo's own `WorkflowRunning`. The sole record of the failure
anywhere in the cluster is the node message (`capture-8-quota.txt`):

```
pods "repro-imagepull-5zflx" is forbidden: exceeded quota: no-pods,
requested: pods=1, used: pods=0, limited: pods=0
```

Any design reading pod status or pod events would see nothing at all here.

Removing the quota caused Argo to create the pod: in `timeline-3-quota-recovery.txt` a pod
exists at the first sample, aged 47 s against a workflow submitted roughly 95 s earlier, so
it was created after the quota was lifted rather than at submission. Argo retries pod
creation, and the condition is therefore recoverable. Note the file does not capture the
transition itself, and it tracks a second workflow rather than the one in `capture-8`.

**5. Stuck pods leave the workflow reporting `Running`, indefinitely.**
`ImagePullBackOff`, `Unschedulable`, `InvalidImageName`, `CreateContainerConfigError` and
admission rejections all left the workflow at `phase: Running` with `workflow.status.message`
empty. **Four workflows were still reporting `Running` 48 hours later**
(`duration-13h.txt`, `duration-48h.txt`). Terminal failures (`OOMKilled`, non-zero exit)
resolve to `Failed` on their own and need no intervention.

**6. Detection is near-instant; the delay is entirely in propagation.**
`Unschedulable` produced `FailedScheduling` **1 second** after submission
(`submit-time.txt`, `submit-time-2.txt`). `ImagePullBackOff` appeared 3 seconds after the
first pull attempt, within 23 s wall-clock, of which about 19 s was Argo pulling its own
`argoexec` image on a cold node. The information exists almost at once and simply never
travels.

**7. Transient failures do recover, and the engine clears the message itself.**
In `7-recovery.yaml` the `waiter` step sat `Unschedulable` while `hog` held 3 CPU, then
scheduled and succeeded within 10 seconds of `hog` finishing, with no intervention. The node
message was **empty** afterwards and no stale reason remained on the pod. Timeline in
`timeline-2.txt` at 13:49:29 → 13:49:39.

Consequence: a consumer must not preserve the previous value of the message field. The engine
does the clearing.

**8. The reason prefix is not stable for a stable cause.**
`ImagePullBackOff` and `ErrImagePull` alternate on a failure that never changed. Sampling the
node message directly (`node-message-oscillation.txt`):

```
13:56:40   ImagePullBackOff: Back-off pulling image "python:99.99.99-nonexistent"…
13:56:51   ErrImagePull: rpc error: code = NotFound…
13:57:01   ImagePullBackOff: Back-off pulling image…
```

Twenty seconds apart, on a failure unchanged for two days. The same alternation appears in
`timeline.txt` and again about 52 s apart in a fresh pod in `timeline-3-quota-recovery.txt`.
Anything timing a failure must not key on the reason string, or the clock resets on every flip.

**9. Retry counts do not separate recoverable from hopeless.**
All stuck reasons retry indefinitely at comparable rates (`retry-counts.txt`):
`ImagePullBackOff` 151 `BackOff`, `CreateContainerConfigError` 26 `Failed`,
`InvalidImageName` 26 `InspectFailed`. The kubelet retries a malformed image reference as
persistently as a transient registry outage. Whether waiting can help is **not observable**
and has to be encoded as knowledge about each reason.

**10. For stuck pods there is nothing to count in the first place.**
Argo sets `restartPolicy: Never` and kubeflow/pipelines does not override it
(`restart-policy.txt`, three pods). A container that never starts never restarts, so
`ImagePullBackOff`, `Unschedulable`, `CreateContainerConfigError`, `InvalidImageName` and
admission rejections all hold a restart count of zero, permanently.

`CrashLoopBackOff` is therefore unreachable for a task container: `4-nonzero-exit.yaml`
failed exactly once as `main: Error (exit code 1)`. It is nonetheless listed as a canonical
runtime-level example in issue #12843 and in the LFX project description.
*Caveat:* a user-declared init container with `restartPolicy: Always` is a native sidecar and
can restart, so it remains reachable there, just not for the task container.

**11. Only `type: Pod` nodes carry messages.**
`7-recovery.yaml` produced `Steps` and `StepGroup` parent nodes, both with empty messages,
while the child `Pod` node held the failure text. Any consumer must read pod nodes and
propagate upward to whichever node it renders.

**12. The failure is always on the container named `main`.**
Every Argo pod carries `main` plus a `wait` sidecar. Across every failure here the reason was
on `main` and `wait` was healthy. Reading `containerStatuses` directly would require selecting
the right container; the node message has already resolved that.

## Limitations: what this does not establish

- **No KFP installed.** These are bare Argo workflows, one pod per step. KFP v2 runs a driver
  pod and an executor pod per task. Which of the two carries the failure, and whether the
  message reaches the node the UI renders, is untested here.
- **Node-level failures untested.** `NodeLost` and `Preempted` need a multi-node cluster with a
  drained node. They are modelled from the Kubernetes API contract (`DisruptionTarget`
  condition, `PreemptionByScheduler` / `TerminationByKubelet`) rather than observed.
- **Retry cadence unresolved.** `ImagePullBackOff` logged 5 `Pulling` events but 151 `BackOff`
  events over a longer window. These do not reconcile cleanly, so no conclusion is drawn about
  when the kubelet stops attempting pulls.
- **`retryStrategy` untested.** KFP compiles task retries into Argo's `RetryStrategy`, which
  creates a new pod per attempt. Whether a failure clock should reset per attempt or accumulate
  across them is an open question.
- **Single sample per scenario**, one cluster, one Kubernetes and one Argo version. Message
  formats vary across versions: the `Unschedulable` text here includes
  `no new claims to deallocate`, which is Kubernetes 1.3x DRA-era phrasing.

## Reproducing

```bash
kind create cluster --name argo-only
kubectl create ns argo
kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v4.0.4/install.yaml \
  --server-side --force-conflicts
kubectl -n argo wait --for=condition=Available --timeout=180s deployment/workflow-controller
kubectl create rolebinding default-admin --clusterrole=admin --serviceaccount=argo:default -n argo

kubectl create -n argo -f 1-imagepull.yaml     # repeat per scenario
./capture.sh <workflow-name>                   # dumps nodes, pod status, events, versions
```

`capture.sh` takes a workflow name and an optional namespace, defaulting to `argo`.

## File index

| | |
|---|---|
| `1-…yaml` … `9-…yaml` | scenario definitions |
| `capture-1…9` | node status, workflow status, pod status and events per scenario |
| `events-1`, `events-2`, `events-3`, `events-9-pvc` | full event streams, Pod-kind only |
| `submit-time`, `submit-time-2` | submission timestamp against first failure event |
| `timeline`, `timeline-2` | repeated sampling: oscillation, and the recovery transition |
| `timeline-3-quota-recovery` | pod creation after the quota was lifted |
| `duration-13h`, `duration-48h` | workflow phase after 13 and 48 hours |
| `node-message-oscillation` | the node message itself sampled every ~10 s |
| `retry-counts` | event counts per reason |
| `restart-policy` | `restartPolicy` and restart counts across three pods |
| `capture.sh` | the capture script |
