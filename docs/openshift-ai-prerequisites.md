# OpenShift AI Prerequisites

What must be in place before running `scripts/setup.sh`. The setup script installs everything else (MCP Gateway operator, Keycloak, Vault, lifecycle operator, gateway instance).

**Cluster**: OpenShift 4.19+ (tested on ROSA 4.21.6)

---

## CLI tools

- `oc` / `kubectl` — logged into the target cluster with cluster-admin
- `helm` v3
- `python3`

## Operators (install via OperatorHub)

| Operator | Channel | Notes |
|----------|---------|-------|
| NVIDIA GPU Operator | `v25.10` | `certified-operators` catalog |
| Node Feature Discovery | `stable` | Required by GPU operator |
| OpenShift Service Mesh 2 | `stable` | Required for Istio proxy (Gateway API dataplane) |
| OpenShift Service Mesh 3 | `stable` | Provides Gateway API CRDs and `openshift-default` GatewayClass |
| OpenShift Serverless | `stable` | Required by KServe |
| cert-manager Operator | `stable-v1` | |
| Red Hat Connectivity Link | `stable` | Includes Kuadrant, Authorino, Limitador |
| RHOAI | `beta` | See [RHOAI setup](#rhoai) below |

## RHOAI

### Catalog source (early-access 3.4)

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-340-catalog
  namespace: openshift-marketplace
spec:
  displayName: Red Hat OpenShift AI 3.4
  image: quay.io/rhoai/rhoai-fbc-fragment@sha256:33562d47f3b5c9fc08e0d7b8ad7e22e2c645532926ae3139afb0d8479c893f28
  sourceType: grpc
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhoai-operator
  namespace: redhat-ods-operator
spec:
  channel: beta
  name: rhods-operator
  source: rhoai-340-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

### DataScienceCluster

Enable KServe, LlamaStack operator, Dashboard, and MLflow.

```yaml
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headed
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Removed
        name: knative-serving
    llamastackoperator:
      managementState: Managed
    mlflowoperator:
      managementState: Managed
    workbenches:
      managementState: Managed
```

### Enable Gen AI Studio + MCP Catalog

After the DataScienceCluster reconciles, enable both feature flags:

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge \
  -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"mcpCatalog":true}}}'
```

Verify:

```bash
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig.genAiStudio} {.spec.dashboardConfig.mcpCatalog}'
# Should show: true true
```

## vLLM model serving

A vLLM ServingRuntime + InferenceService must be deployed and running before creating a Playground. Key requirements:

- `--served-model-name` must match the InferenceService name
- `--enable-auto-tool-choice --tool-call-parser openai` for MCP tool calling
- `opendatahub.io/genai-asset: "true"` label on the InferenceService (makes it discoverable by Gen AI Studio)

### Example ServingRuntime

Adjust GPU resources, node selector, and `--max-model-len` for your hardware.

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-cuda129-20b-runtime
  namespace: gpt-oss
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: vLLM with Tool Calling (20B)
spec:
  containers:
  - name: kserve-container
    image: registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9@sha256:abf0fd7398a18c47a754218b0cbd76ea300b0c6da5fb8d801db8c165df5022ca
    command: ["python", "-m", "vllm.entrypoints.openai.api_server"]
    args:
    - --model
    - /mnt/models
    - --port
    - "8080"
    - --max-model-len
    - "8192"
    - --gpu-memory-utilization
    - "0.95"
    - --dtype
    - bfloat16
    - --served-model-name
    - vllm-20b
    - --enable-auto-tool-choice
    - --tool-call-parser
    - openai
    env:
    - name: HF_HOME
      value: /tmp/hf_home
    - name: TRANSFORMERS_CACHE
      value: /tmp/transformers_cache
    ports:
    - containerPort: 8080
      name: http
      protocol: TCP
    resources:
      limits:
        cpu: "16"
        memory: 64Gi
        nvidia.com/gpu: "1"
      requests:
        cpu: "8"
        memory: 32Gi
        nvidia.com/gpu: "1"
    volumeMounts:
    - mountPath: /dev/shm
      name: shm
    - mountPath: /mnt/models
      name: models-pvc
  multiModel: false
  runtimeClassName: nvidia
  supportedModelFormats:
  - autoSelect: true
    name: vLLM
    version: "1"
  volumes:
  - emptyDir:
      medium: Memory
      sizeLimit: 16Gi
    name: shm
  - name: models-pvc
    persistentVolumeClaim:
      claimName: gpt-oss-20b-models
```

> **Note**: `--tool-call-parser` value depends on the model family. Use `openai` for gpt-oss models, `hermes` for Qwen/ChatML-style models, `llama3` for Llama 3.x, `mistral` for Mistral. Check vLLM docs for your model.

### Example InferenceService

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: vllm-20b
  namespace: gpt-oss
  labels:
    opendatahub.io/genai-asset: "true"
  annotations:
    openshift.io/display-name: GPT-OSS-20B Model
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
        version: "1"
      runtime: vllm-cuda129-20b-runtime
      storageUri: pvc://gpt-oss-20b-models/gpt-oss-20b
```

## What setup.sh installs

Everything below is handled by `scripts/setup.sh` — do not install manually:

| Phase | Component |
|-------|-----------|
| 1 | MCP Gateway operator, RHBK (Keycloak) operator |
| 2 | Keycloak instance, realm, users, groups |
| 3 | MCP Lifecycle Operator |
| 4 | Vault (Helm), JWT auth, per-user policy |
| 5 | Kuadrant CR, MCP Gateway instance (team-a), Route, RHOAI registration |
| 6 | Playground validation (LlamaStack created via RHOAI Dashboard UI) |
