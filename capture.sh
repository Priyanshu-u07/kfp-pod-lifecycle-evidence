#!/usr/bin/env bash
# Capture what Argo and Kubernetes actually record for a failing workflow.
# Usage:  ./capture.sh <workflow-name> [namespace]
# Uses only kubectl jsonpath, so no jq needed.

WF="$1"
NS="${2:-argo}"

if [ -z "$WF" ]; then
  echo "usage: $0 <workflow-name> [namespace]"
  echo ""
  echo "workflows in $NS:"
  kubectl get wf -n "$NS" --no-headers 2>/dev/null | awk '{print "  " $1 "  (" $2 ")"}'
  exit 1
fi

echo "################ ARGO NODES ################"
echo "displayName | type | phase | message"
echo "-------------------------------------------"
kubectl get wf -n "$NS" "$WF" -o jsonpath='{range .status.nodes.*}{.displayName}{" | "}{.type}{" | "}{.phase}{" | "}{.message}{"\n"}{end}'

echo ""
echo "################ WORKFLOW-LEVEL ################"
kubectl get wf -n "$NS" "$WF" -o jsonpath='phase={.status.phase}{"\n"}message={.status.message}{"\n"}startedAt={.status.startedAt}{"\n"}'

echo ""
echo "################ POD STATUS ################"
for POD in $(kubectl get pods -n "$NS" -l workflows.argoproj.io/workflow="$WF" -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- pod: $POD"
  kubectl get pod -n "$NS" "$POD" -o jsonpath='  phase={.status.phase}{"\n"}'

  echo "  conditions (type / status / reason):"
  kubectl get pod -n "$NS" "$POD" -o jsonpath='{range .status.conditions[*]}    {.type} / {.status} / {.reason}{"\n"}{end}'

  echo "  containerStatuses (name / waiting.reason / terminated.reason):"
  kubectl get pod -n "$NS" "$POD" -o jsonpath='{range .status.containerStatuses[*]}    {.name} / {.state.waiting.reason} / {.state.terminated.reason}{"\n"}{end}'

  echo "  waiting.message:"
  kubectl get pod -n "$NS" "$POD" -o jsonpath='{range .status.containerStatuses[*]}    {.state.waiting.message}{"\n"}{end}'
done

echo ""
echo "################ EVENTS ################"
kubectl get events -n "$NS" --field-selector involvedObject.kind=Pod \
  --sort-by=.lastTimestamp -o custom-columns=TYPE:.type,REASON:.reason,OBJ:.involvedObject.name,MSG:.message 2>/dev/null | tail -20

echo ""
echo "################ VERSIONS ################"
kubectl version -o json 2>/dev/null | grep -E '"gitVersion"' | head -2
kubectl get deploy -n "$NS" workflow-controller -o jsonpath='argo-controller-image={.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null
