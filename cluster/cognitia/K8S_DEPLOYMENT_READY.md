# Cognitia v2 - Kubernetes Deployment Ready

## ✅ Completed Tasks

### 1. Docker Images Built and Pushed
All images have been built and pushed to Docker Hub under `fabbricca/*`:

- **fabbricca/cognitia-api:latest** (also tagged as v2.0.0)
  - SHA256: `c709cb38d1fda49688b198e7852428fad791373a95effdcff0479e16be86582b`
  - Size: ~482MB
  - Base: python:3.12-slim
  - Features: FastAPI, SQLAlchemy async, Alembic, JWT auth, Celery client

- **fabbricca/cognitia-celery-worker:latest** (also tagged as v2.0.0)
  - Same SHA256 (shared base image)
  - Size: ~482MB
  - Purpose: Background task processing (emails, AI generation)
  - Concurrency: 4 workers per pod (configurable)

- **fabbricca/cognitia-celery-beat:latest** (also tagged as v2.0.0)
  - Same SHA256 (shared base image)
  - Size: ~482MB
  - Purpose: Periodic task scheduler
  - Tasks: Token cleanup (hourly), metrics aggregation (daily), subscription checks (daily)

### 2. Kubernetes Manifests Created

All manifests are in `/home/iberu/Documents/homeserver/cluster/cognitia/`:

#### New Files (v2)
- **redis-pvc.yaml** - 1Gi persistent volume for Redis data
- **redis-deployment.yaml** - Redis 7 Alpine deployment with persistence
- **redis-service.yaml** - ClusterIP service on port 6379
- **celery-worker-deployment.yaml** - 2 replicas, auto-scaling ready
- **celery-beat-deployment.yaml** - 1 replica (scheduler, must be singleton)

#### Updated Files
- **api-configmap.yaml** - Added:
  - REDIS_URL
  - EMAIL_MODE, SMTP_*, SENDGRID_* settings
  - FRONTEND_URL for email links

- **api-secret.yaml** - Added:
  - SMTP_PASSWORD
  - SENDGRID_API_KEY
  - STRIPE_SECRET_KEY
  - STRIPE_WEBHOOK_SECRET

- **postgres-deployment.yaml** - Changed to postgres:15-alpine (from 16)

- **kustomization.yaml** - Added all new resources in proper order

### 3. Kustomization Validated
```bash
✅ Kustomization is valid
```

## 📋 Deployment Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Ingress                              │
│              (cognitia.iberu.dev)                           │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│                    API Server (1 replica)                     │
│              fabbricca/cognitia-api:latest                   │
│  • FastAPI REST API (31 endpoints)                          │
│  • WebSocket proxy to Core GPU server                       │
│  • JWT authentication                                        │
│  • File serving (avatars, static)                           │
└─────┬────────────────┬────────────────┬─────────────────────┘
      │                │                │
      ▼                ▼                ▼
┌──────────┐   ┌──────────────┐   ┌──────────────────┐
│PostgreSQL│   │    Redis     │   │  Celery Worker   │
│   (1)    │   │     (1)      │   │    (2 replicas)  │
│  15-alpine│   │  7-alpine   │   │  • Email tasks   │
│          │   │              │   │  • AI generation │
│ • Users  │   │ • Task queue │   │  • Retries       │
│ • Chats  │   │ • Celery     │   └──────────────────┘
│ • Chars  │   │   backend    │            ▲
│ • Subs   │   └──────────────┘            │
└──────────┘            │                  │
                        │                  │
                        ▼                  │
                 ┌──────────────┐          │
                 │ Celery Beat  │──────────┘
                 │  (1 replica) │
                 │ • Scheduler  │
                 │ • Periodic   │
                 │   tasks      │
                 └──────────────┘
```

## 🚀 Next Steps - What You Need to Do

### 1. Review and Commit to Homeserver Repo
```bash
cd /home/iberu/Documents/homeserver
git status
git add cluster/cognitia/
git commit -m "feat: add Cognitia v2 K8s manifests with Redis and Celery

- Add Redis deployment for task queue and caching
- Add Celery worker deployment (2 replicas) for background jobs
- Add Celery beat deployment (1 replica) for periodic tasks
- Update API configmap with Redis and email settings
- Update API secrets with email and Stripe keys
- Update kustomization with all new v2 resources
- Update PostgreSQL to version 15-alpine

Docker images pushed:
- fabbricca/cognitia-api:v2.0.0
- fabbricca/cognitia-celery-worker:v2.0.0
- fabbricca/cognitia-celery-beat:v2.0.0
"
```

### 2. Push to GitHub (YOU WILL DO THIS)
```bash
git push origin main
```

### 3. Flux CD Auto-Deployment
Once pushed, Flux CD will automatically:
1. Detect the changes in the homeserver repo
2. Apply the kustomization to the `cognitia` namespace
3. Deploy Redis, Celery worker, and Celery beat
4. Update the API deployment to use the new v2 image

### 4. Monitor Deployment
```bash
# Watch pods come up
kubectl get pods -n cognitia -w

# Check Flux reconciliation
flux get kustomizations -n flux-system

# View logs
kubectl logs -n cognitia -l app.kubernetes.io/name=cognitia-api --tail=50
kubectl logs -n cognitia -l app.kubernetes.io/name=cognitia-celery-worker --tail=50
kubectl logs -n cognitia -l app.kubernetes.io/name=cognitia-celery-beat --tail=50
```

### 5. Post-Deployment Verification
```bash
# Check all pods are running
kubectl get pods -n cognitia

# Expected output:
# cognitia-api-xxx              1/1     Running
# cognitia-postgres-xxx         1/1     Running
# cognitia-redis-xxx            1/1     Running
# cognitia-celery-worker-xxx    1/1     Running (x2)
# cognitia-celery-beat-xxx      1/1     Running

# Test API health
curl https://cognitia.iberu.dev/health

# Test v2 API endpoints
curl https://cognitia.iberu.dev/docs
```

## 🔧 Configuration Notes

### Email Service
Currently set to `EMAIL_MODE: "console"` (logs to stdout).

To enable real email:
1. **For SMTP** (Gmail, etc.):
   - Update `EMAIL_MODE: "smtp"` in api-configmap.yaml
   - Set SMTP_HOST, SMTP_PORT, SMTP_USER in configmap
   - Set SMTP_PASSWORD in api-secret.yaml

2. **For SendGrid**:
   - Update `EMAIL_MODE: "sendgrid"` in api-configmap.yaml
   - Set SENDGRID_API_KEY in api-secret.yaml

### Stripe Payments
To enable Stripe:
1. Add your Stripe secret key to `api-secret.yaml`
2. Add webhook secret to `api-secret.yaml`
3. Configure Stripe webhooks to point to: `https://cognitia.iberu.dev/api/v1/webhook/stripe`

### Scaling
```bash
# Scale Celery workers
kubectl scale deployment cognitia-celery-worker -n cognitia --replicas=4

# Scale API (requires load balancer)
kubectl scale deployment cognitia-api -n cognitia --replicas=2
```

## 📊 Resource Allocation

| Component      | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------------|-------------|-----------|----------------|--------------|
| API           | 50m         | 500m      | 128Mi          | 512Mi        |
| PostgreSQL    | 100m        | 500m      | 256Mi          | 512Mi        |
| Redis         | 50m         | 250m      | 64Mi           | 256Mi        |
| Celery Worker | 100m        | 1000m     | 256Mi          | 1Gi          |
| Celery Beat   | 50m         | 200m      | 128Mi          | 256Mi        |
| **TOTAL**     | **350m**    | **2450m** | **832Mi**      | **2.5Gi**    |

Per worker replica, total scales with 2 workers to **550m / 3450m CPU** and **1.1Gi / 3.5Gi RAM**.

## 🎯 Migration Status

- ✅ Phase 0: Docker Setup
- ✅ Phase 1: Database Migration (Alembic)
- ✅ Phase 2: Repository & Service Layer
- ✅ Phase 3: API v2 Endpoints (31 endpoints)
- ✅ Phase 4: Background Jobs (Celery)
- ✅ Phase 5: Documentation
- ✅ **Phase 6: K8s Deployment Preparation** ← YOU ARE HERE

## 📝 Important Files

- [MIGRATION_V2.md](/home/iberu/Documents/cognitia/MIGRATION_V2.md) - Complete migration guide
- [DEPLOYMENT.md](/home/iberu/Documents/cognitia/DEPLOYMENT.md) - Detailed K8s deployment guide
- [QUICKSTART.md](/home/iberu/Documents/cognitia/QUICKSTART.md) - Quick start guide
- [MIGRATION_COMPLETE.md](/home/iberu/Documents/cognitia/MIGRATION_COMPLETE.md) - Summary of all work

---

**Ready for deployment!** Once you push the homeserver repo, Flux CD will handle the rest.
