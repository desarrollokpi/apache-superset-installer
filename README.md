# Setup multi‑entorno de Superset

Este repositorio contiene un envoltorio ligero alrededor del setup oficial de Apache Superset en Docker, con tres entornos diferenciados:

- `local` – stack rápido en localhost, sin reverse proxy.
- `dev` – stack de desarrollo detrás de Traefik, enrutado por hostname.
- `prod` – stack tipo producción detrás de Traefik, con validación estricta de variables de entorno.

Todo lo que hay en `setup-superset/` son configuraciones y scripts versionados; todo el estado en tiempo de ejecución vive bajo `superset-files/` y se puede borrar sin riesgo para resetear cualquier entorno.

```text
.
├── setup-superset/          # Scripts + docker-compose por entorno
│   ├── docker-compose.superset.local.yaml
│   ├── docker-compose.superset.dev.yaml
│   ├── docker-compose.superset.prod.yaml
│   ├── manage-superset.sh   # Punto de entrada único para todos los entornos
│   ├── start-*.sh / stop-*.sh (wrappers finos)
│   └── superset-config/     # Config de Superset + script de init
│       ├── superset_config.py
│       └── init_superset.sh
└── superset-files/          # Workspaces generados (ignorados por git)
    ├── superset-local/
    ├── superset-dev/
    └── superset-prod/
```

## Prerrequisitos

- Docker Engine + plugin Docker Compose (v2).
- `openssl` (solo necesario si añades generación de certificados TLS; ahora mismo Traefik escucha en HTTP).
- Entrada en `/etc/hosts` (o DNS equivalente) para los hostnames que quieras usar en `dev` y `prod`.

---

## Resumen de entornos

### Local (sin reverse proxy)

- Compose: `setup-superset/docker-compose.superset.local.yaml`
- Workspace: `superset-files/superset-local/`
- Servicios:
  - `postgres` (`superset_local_db`)
  - `redis` (`superset_local_cache`)
  - `superset-init` (`superset_local_init`)
  - `superset` web (`superset_local_app`)
  - `superset-worker` / `superset-worker-beat` (Celery, opcional; puedes comentarlos si no necesitas tareas async)
- Red: `superset_local`
- Puertos:
  - `localhost:8088` → Superset web
  - `localhost:5432` → Postgres (útil para conectarse desde herramientas externas)
- Acceso: `http://localhost:8088`

Este entorno está pensado para pruebas rápidas directamente contra Superset, sin layer de reverse proxy.

### Dev (Traefik como reverse proxy)

- Compose: `setup-superset/docker-compose.superset.dev.yaml`
- Workspace: `superset-files/superset-dev/`
- Servicios:
  - `postgres`, `redis`
  - `superset-init` → aplica migraciones y bootstrap del admin
  - `superset` web (`superset_dev_app`)
  - `superset-worker`, `superset-worker-beat` (Celery; puedes deshabilitarlos comentando los servicios)
  - `traefik` (`superset_dev_traefik`) – reverse proxy con provider Docker
- Red: `superset_dev`
- Puertos:
  - `80` → entrypoint `web` de Traefik
  - `8088` → puerto interno de Superset (también expuesto para debug)
- Enrutamiento:
  - Hostname: `${DEV_SUPERSET_HOST:-dev.kpimanager.com}`
  - Etiquetas Traefik en `superset_dev_app`:
    - `traefik.http.routers.superset_dev.rule=Host(\`${DEV_SUPERSET_HOST:-dev.kpimanager.com}\`)`
    - `traefik.http.routers.superset_dev.entrypoints=web`
    - `traefik.http.services.superset_dev.loadbalancer.server.port=8088`

Para acceder a Superset en `dev`:

1. Asegúrate de tener en `/etc/hosts`:
   ```text
   127.0.0.1 dev.kpimanager.com
   ```
2. Abre `http://dev.kpimanager.com` en el navegador.

### Prod (tipo producción con Traefik)

- Compose: `setup-superset/docker-compose.superset.prod.yaml`
- Workspace: `superset-files/superset-prod/`
- Servicios:
  - `postgres`, `redis`
  - `superset-init` (`superset_prod_init`)
  - `superset` web (`superset_prod_app`)
  - `superset-worker`, `superset-worker-beat` (Celery)
  - `traefik` (`superset_prod_traefik`)
- Red: `superset_prod`
- Puertos:
  - `80` → entrypoint `web` de Traefik
  - `8088` → puerto interno de Superset (puedes restringirlo más adelante si quieres)
- Enrutamiento:
  - Hostname: `${SUPERSET_FQDN:-superset.kpimanager.com}`
  - Etiquetas Traefik en `superset_prod_app`:
    - `traefik.http.routers.superset_prod.rule=Host(\`${SUPERSET_FQDN:-superset.kpimanager.com}\`)`
    - `traefik.http.routers.superset_prod.entrypoints=web`
    - `traefik.http.services.superset_prod.loadbalancer.server.port=8088`

Variables obligatorias para `prod`:

- `SUPERSET_VERSION` – tag de la imagen (ej. `5.0.0`).
- `SUPERSET_SECRET_KEY` – secret robusto para Superset/Flask.

Normalmente se definen en `.env.prod` o como variables de entorno antes de levantar el stack.

---

## Usuario admin y gestión de contraseña

Todos los entornos usan el script `setup-superset/superset-config/init_superset.sh` para bootstrap:

1. Ejecuta `/app/docker/docker-bootstrap.sh` (script oficial upstream).
2. Aplica migraciones (`superset db upgrade`).
3. Crea o actualiza el usuario admin.
4. Inicializa roles y permisos (`superset init`).
5. Opcionalmente carga datos de ejemplo si `SUPERSET_LOAD_EXAMPLES=yes`.

El usuario admin se controla por variables de entorno:

- `SUPERSET_ADMIN_USERNAME` (por defecto: `admin`)
- `SUPERSET_ADMIN_EMAIL` (por defecto: `admin@superset.com`)
- `SUPERSET_ADMIN_FIRSTNAME` (por defecto: `Superset`)
- `SUPERSET_ADMIN_LASTNAME` (por defecto: `Admin`)
- `SUPERSET_ADMIN_PASSWORD` (opcional; si está vacío se genera una contraseña aleatoria)
- `SUPERSET_ARTIFACTS_DIR` (por defecto: `/app/setup-artifacts`)

Comportamiento de la contraseña:

- Si `SUPERSET_ADMIN_PASSWORD` **no está** definida:
  - Si ya existe `${SUPERSET_ARTIFACTS_DIR}/generated_admin_password.txt` con contenido, se reutiliza esa contraseña.
  - Si no existe o está vacío, se genera una contraseña aleatoria de 24 caracteres, se imprime y se guarda en:
    ```text
    ${SUPERSET_ARTIFACTS_DIR}/generated_admin_password.txt
    ```
    con permisos `600`.
- En el primer arranque se usa `superset fab create-admin`.
- Si el usuario admin ya existe, el script actualiza:
  - email, nombre, apellido, flag `active` y contraseña usando `superset shell`.

En el host, `SUPERSET_ARTIFACTS_DIR` se monta a `./artifacts` por entorno:

- Local: `superset-files/superset-local/artifacts/generated_admin_password.txt`
- Dev:   `superset-files/superset-dev/artifacts/generated_admin_password.txt`
- Prod:  `superset-files/superset-prod/artifacts/generated_admin_password.txt`

Ese archivo es el punto de referencia para conocer la contraseña actual del admin en cada entorno.

---

## Gestor unificado: `manage-superset.sh`

El script `setup-superset/manage-superset.sh` es el punto de entrada único para arrancar/parar cualquier entorno.

```bash
# Sintaxis
./setup-superset/manage-superset.sh <entorno> <acción> [opciones]

# Entornos
entorno = local | dev | prod

# Acciones
acción = up | down
```

### Qué hace `manage-superset.sh`

Para `up`:

1. Carga variables desde:
   - `./.env`
   - `./.env.<entorno>` (si existe).
2. Prepara un workspace:
   - `superset-files/superset-<entorno>/`
   - Copia `docker-compose.superset.<entorno>.yaml` al workspace.
   - Copia `superset-config/superset_config.py` y `superset-config/init_superset.sh` al workspace.
3. Valida variables críticas para `prod`:
   - Falla si `SUPERSET_VERSION` o `SUPERSET_SECRET_KEY` no están definidas.
4. Lanza:
   ```bash
   docker compose -f superset-files/superset-<entorno>/docker-compose.superset.<entorno>.yaml \
     --project-name superset_<entorno> up -d --remove-orphans
   ```
5. Imprime la ruta al archivo de contraseña de admin.

Para `down`:

1. Carga variables de entorno igual que en `up`.
2. Ejecuta:
   ```bash
   docker compose -f superset-files/superset-<entorno>/docker-compose.superset.<entorno>.yaml \
     --project-name superset_<entorno> down [ -v ]
   ```
   - Añade `-v` si pasas `--with-volumes`.
3. Si se usa `--with-volumes`, elimina también el workspace `superset-files/superset-<entorno>/`.

### Wrappers de conveniencia

Los scripts `start-*.sh` / `stop-*.sh` solo delegan en `manage-superset.sh`:

```bash
# Arrancar
./setup-superset/start-local.sh     # → manage-superset.sh local up
./setup-superset/start-dev.sh       # → manage-superset.sh dev up
./setup-superset/start-prod.sh      # → manage-superset.sh prod up

# Parar
./setup-superset/stop-local.sh      # → manage-superset.sh local down
./setup-superset/stop-dev.sh        # → manage-superset.sh dev down
./setup-superset/stop-prod.sh       # → manage-superset.sh prod down

# Parar y borrar volúmenes + workspace
./setup-superset/stop-dev.sh --with-volumes
```

También puedes llamar directamente a `manage-superset.sh` si quieres extenderlo con nuevos comandos (por ejemplo `logs`, `ps`, etc.).

---

## Tareas habituales

### Arrancar una instancia local limpia

```bash
./setup-superset/stop-local.sh --with-volumes   # reset opcional
./setup-superset/start-local.sh

docker compose --project-name superset_local \
  -f superset-files/superset-local/docker-compose.superset.local.yaml logs -f superset
```

Superset quedará disponible en `http://localhost:8088`. La contraseña del admin está en:

```bash
cat superset-files/superset-local/artifacts/generated_admin_password.txt
```

### Arrancar dev con Traefik

```bash
echo "127.0.0.1 dev.kpimanager.com" | sudo tee -a /etc/hosts

./setup-superset/stop-dev.sh --with-volumes
./setup-superset/start-dev.sh
```

Luego abre `http://dev.kpimanager.com`. Logs útiles:

```bash
docker compose --project-name superset_dev \
  -f superset-files/superset-dev/docker-compose.superset.dev.yaml logs -f superset
```

### Arrancar el stack tipo producción con Traefik

Primero define las variables necesarias (ej. en `.env.prod` o en tu shell):

```bash
export SUPERSET_VERSION=5.0.0
export SUPERSET_SECRET_KEY="cambia_esto_por_un_secret_fuerte"
export SUPERSET_FQDN="superset.kpimanager.com"
```

Luego:

```bash
./setup-superset/stop-prod.sh --with-volumes
./setup-superset/start-prod.sh
```

Asegúrate de que `SUPERSET_FQDN` resuelve a la máquina donde corre Traefik y abre `http://superset.kpimanager.com`.

---

## Troubleshooting

- **Contraseña de admin**: consulta siempre el archivo `generated_admin_password.txt` dentro del directorio `artifacts` del workspace del entorno.
- **Resetear entorno**: usa `stop-<entorno>.sh --with-volumes` o borra el directorio `superset-files/superset-<entorno>`.
- **Puertos ocupados**:
  - Verifica que no haya otros servicios usando los puertos 80 / 8088 / 5432.
- **Traefik no enruta**:
  - Confirma que los hostnames (`DEV_SUPERSET_HOST`, `SUPERSET_FQDN`) coinciden con tus entradas en `/etc/hosts` o tus registros DNS.
  - Revisa los logs de Traefik, por ejemplo en dev:
    ```bash
    docker compose --project-name superset_dev \
      -f superset-files/superset-dev/docker-compose.superset.dev.yaml logs -f traefik
    ``` 
