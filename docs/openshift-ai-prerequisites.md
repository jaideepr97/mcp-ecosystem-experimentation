# OpenShift AI Baseline Setup

Minimal resources needed on a fresh OpenShift 4.19+ cluster to reach the starting point for MCP Gateway integration with the Gen AI Playground.

## Operator prerequisites

These must be installed via OperatorHub before anything below. Standard installs, no custom config needed:

- **NVIDIA GPU Operator** (`certified-operators`, channel `v25.10`)
- **Node Feature Discovery** (`redhat-operators`, channel `stable`)
- **OpenShift Service Mesh 2 & 3** (`redhat-operators`, channel `stable`) — provides Gateway API CRDs
- **OpenShift Serverless** (`redhat-operators`, channel `stable`) — required by KServe
- **cert-manager Operator** (`redhat-operators`, channel `stable-v1`)

## 1. RHOAI Operator

Using early-access 3.4. Create the catalog source first, then the subscription.

```yaml
# infrastructure/openshift-ai/01-rhoai-catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-catalog-dev
  namespace: openshift-marketplace
spec:
  displayName: Red Hat OpenShift AI
  image: quay.io/rhoai/rhoai-fbc-fragment@sha256:ebad4fd69dc200adf641e3c427baaf9a519449b8e7562c90f2c6688b07393274
  sourceType: grpc
---
# infrastructure/openshift-ai/02-rhoai-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhoai-operator-dev
  namespace: redhat-ods-operator
spec:
  channel: beta
  name: rhods-operator
  source: rhoai-catalog-dev
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

## 2. DataScienceCluster

Enables the components we need: KServe (model serving), Llama Stack Operator, Dashboard, MLflow.

```yaml
# infrastructure/openshift-ai/03-datasciencecluster.yaml
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

After this is reconciled, verify Gen AI Studio is enabled:

```bash
oc get odhdashboardconfig -n redhat-ods-applications -o yaml | grep genAiStudio
# Should show: genAiStudio: true
```

## 3. vLLM ServingRuntime

Custom runtime with tool-calling enabled. Adjust GPU resources and node selector for your hardware.

```yaml
# infrastructure/openshift-ai/04-vllm-servingruntime.yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-cuda129-20b-runtime
  namespace: gpt-oss
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: vLLM with Tool Calling
spec:
  annotations:
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
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

## 4. InferenceService

```yaml
# infrastructure/openshift-ai/05-inferenceservice.yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: vllm-20b
  namespace: gpt-oss
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

## 5. Llama Stack

### 5.1 Config (ConfigMap)

```yaml
# infrastructure/openshift-ai/06-llamastack-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: llama-stack-mcp-config
  namespace: gpt-oss
data:
  config.yaml: |
    version: 2
    distro_name: starter
    apis:
    - agents
    - inference
    - tool_runtime
    - vector_io
    - files
    - file_processors
    providers:
      inference:
      - provider_id: vllm
        provider_type: remote::vllm
        config:
          base_url: https://vllm-20b-gpt-oss.apps.rosa.agentic-mcp.jolf.p3.openshiftapps.com/v1
          max_tokens: 4096
          api_token: fake
          network:
            tls:
              verify: false
      vector_io:
      - provider_id: faiss
        provider_type: inline::faiss
        config:
          persistence:
            namespace: vector_io::faiss
            backend: kv_default
      files:
      - provider_id: meta-reference-files
        provider_type: inline::localfs
        config:
          storage_dir: /data/files
          metadata_store:
            table_name: files_metadata
            backend: sql_default
      file_processors:
      - provider_id: pypdf
        provider_type: inline::pypdf
      agents:
      - provider_id: meta-reference
        provider_type: inline::meta-reference
        config:
          persistence:
            agent_state:
              namespace: agents
              backend: kv_default
            responses:
              table_name: responses
              backend: sql_default
      tool_runtime:
      - provider_id: rag-runtime
        provider_type: inline::rag-runtime
      # TODO: Add remote::model-context-protocol provider pointing at MCP Gateway
    storage:
      backends:
        kv_default:
          type: kv_sqlite
          db_path: /data/sqlite/kv.db
        sql_default:
          type: sql_sqlite
          db_path: /data/sqlite/sql.db
      stores:
        metadata:
          namespace: registry
          backend: kv_default
        inference:
          table_name: inference_store
          backend: sql_default
        conversations:
          table_name: openai_conversations
          backend: sql_default
        prompts:
          namespace: prompts
          backend: kv_default
        connectors:
          namespace: connectors
          backend: kv_default
    server:
      port: 8321
    vector_stores:
      default_provider_id: faiss
```

### 5.2 LlamaStackDistribution

```yaml
# infrastructure/openshift-ai/07-llamastack-distribution.yaml
apiVersion: llamastack.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  name: llama-stack-mcp
  namespace: gpt-oss
spec:
  network:
    exposeRoute: true
  replicas: 1
  server:
    containerSpec:
      port: 8321
    distribution:
      image: docker.io/llamastack/distribution-starter:0.6.1
    storage:
      mountPath: /data
      size: 5Gi
    userConfig:
      configMapName: llama-stack-mcp-config
      configMapNamespace: gpt-oss
```

## Apply order

```bash
# 1. Operator prerequisites (OperatorHub — GPU, NFD, Service Mesh, Serverless, cert-manager)

# 2. RHOAI
oc apply -f infrastructure/openshift-ai/01-rhoai-catalogsource.yaml
# Wait for catalog pod to be ready
oc apply -f infrastructure/openshift-ai/02-rhoai-subscription.yaml
# Wait for RHOAI operator to install
oc apply -f infrastructure/openshift-ai/03-datasciencecluster.yaml
# Wait for all components to reconcile

# 3. Model serving (gpt-oss namespace)
oc new-project gpt-oss
oc apply -f infrastructure/openshift-ai/04-vllm-servingruntime.yaml
oc apply -f infrastructure/openshift-ai/05-inferenceservice.yaml
# Wait for model to be ready

# 4. Llama Stack (test-jd namespace)
oc new-project test-jd
oc apply -f infrastructure/openshift-ai/06-llamastack-config.yaml
oc apply -f infrastructure/openshift-ai/07-llamastack-distribution.yaml
# Wait for pod to be ready; if route not auto-created:
oc apply -f infrastructure/openshift-ai/08-llamastack-route.yaml

# 5. Red Hat Connectivity Link (provides AuthPolicy, RateLimitPolicy)
oc apply -f infrastructure/openshift-ai/09-connectivity-link-subscription.yaml
# Approve InstallPlan in openshift-operators namespace, wait for operator

# 6. MCP Gateway (test-jd namespace)
# Raw manifests — do NOT use Helm chart (service selector bug, see session log #8)
oc apply -f infrastructure/openshift-ai/10-mcp-controller-rbac.yaml
oc apply -f infrastructure/openshift-ai/11-mcp-controller-deployment.yaml
# Wait for controller pod to be ready
oc apply -f infrastructure/openshift-ai/12-mcp-gateway.yaml
oc apply -f infrastructure/openshift-ai/13-mcp-gateway-extension.yaml
# Wait for controller to create broker, service, EnvoyFilter

# 7. Test MCP server (test-jd namespace)
oc apply -f infrastructure/openshift-ai/14-test-mcp-server.yaml
# Restart broker to pick up new server config:
oc rollout restart deployment/mcp-gateway -n test-jd
```
