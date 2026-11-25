# @velastack/action

Deploy a [VelaStack](https://velastack.dev) app to your own server from GitHub Actions.

The action builds the app on the runner and hands it to `vela deploy` over SSH — the same command you run locally, so a deploy from CI and a deploy from your laptop do exactly the same thing.

## Quick start

The server has to be prepared once, and the app deployed once, from your machine.
Then one command writes the workflow:

```sh
vela provision root@your-server
vela deploy --server root@your-server --domain example.com
vela enable ci
git add .vela/project.json .github/workflows/deploy.yml && git commit -m "Deploy on push"
```

`vela enable ci` writes `.github/workflows/deploy.yml` for this action, checks
what the workflow depends on (a lockfile, a deployed target, a GitHub remote)
and, with `--setup-key`, creates a deploy key for CI: it generates a keypair,
adds the public half to the server's `authorized_keys` and stores the private
half as the `SSH_PRIVATE_KEY` repository secret with the `gh` CLI. Without
`--setup-key` it prints those steps for you to run.

The rest of this page is what that command sets up, for doing it by hand or
changing it afterwards.

## Before you start

The server has to be prepared once, and the app deployed once, from your machine:

```sh
vela provision root@your-server
vela deploy --server root@your-server --domain example.com
git add .vela/project.json && git commit -m "Add the vela project id"
```

That first deploy is what gives the project its permanent app id, and records
which server and domain the target lives on. The action refuses to run until
`.vela/project.json` is committed: a runner that finds no id mints a new one,
and since its checkout is thrown away at the end of the job, every deploy would
land as a brand new app and orphan the last one on the server.

Then give the action a way in (`vela enable ci --setup-key` does these three):

1. Create a keypair for CI: `ssh-keygen -t ed25519 -f vela-deploy -C "github actions"`
2. Add the public key to the server: `ssh-copy-id -i vela-deploy.pub root@your-server`
3. Add the private key to the repository as a secret named `SSH_PRIVATE_KEY`

## Usage

```yaml
name: Deploy

on:
  push:
    branches: [main]

concurrency:
  group: deploy-prod
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: velastack/action@v1
        with:
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
        env:
          # Placeholders, for a project with a PocketBase backend. See
          # "Secrets and environment" below.
          POCKETBASE_SUPERUSER_EMAIL: ci@example.com
          POCKETBASE_SUPERUSER_PASSWORD: ci-build-only-password
```

That is the whole thing. The action installs dependencies, builds, uploads a release, runs migrations, restarts the services and health-checks the result. A deploy that fails its health check puts the previous release back and fails the job.

Use a `concurrency` group so two pushes cannot deploy over each other.

### Which target, which server

`target` defaults to `production`, which is the `prod` entry under `targets` in
`.vela/project.json`: `production` and `prod` are two spellings of the same
target, so there is nothing to set for the usual case, and setting
`target: prod` deploys the same copy. Any other name (`target: staging`) is a
separate copy of the app.

`server` and `domain` do not need to be in the workflow. The first deploy of a
target records both in `.vela/project.json`, and the action reads the server
from there: `targets.prod.server` for production, `targets.<name>.server` for a
named target, and for pull request previews `targets.preview.server`, falling
back to production's server. Set `server` only to deploy somewhere the file
does not name, and `domain` only to change it. A run with no `server` input and
no recorded server for its target fails before anything is built, and says so.

### npm and pnpm

The action installs with whichever lockfile is committed:

| Lockfile | Install |
| --- | --- |
| `package-lock.json` | `npm ci`, with the npm cache restored by `actions/setup-node` |
| `pnpm-lock.yaml` only | `pnpm install --frozen-lockfile` |
| both | npm, the same choice the CLI makes |
| `yarn.lock`, `bun.lock` or none | the run fails early, asking for an npm or pnpm lockfile |

For pnpm, the version is the one in `package.json`'s `packageManager` field
(`"packageManager": "pnpm@10.4.1"`) when there is one, and otherwise the newest
major that reads the lockfile as written. It is installed with
`npm install --global`, since current Node.js releases no longer ship corepack.
To install some other way, do it in an earlier step and set `install: false`.

### Node.js version

The build runs on the first of: the `node-version` input; `.nvmrc` or
`.node-version` in the working directory; the same files at the repository
root; Node.js 26. Commit an `.nvmrc` so CI and your machine agree.

## Recording deploys on velastack.dev

A project that has been `vela link`ed can have every deploy from CI show up on
its dashboard: who deployed, which commit, which target, where it landed. Create
an API key at <https://velastack.dev/api-keys/new>, store it as a repository
secret, and pass it in:

```yaml
      - uses: velastack/action@v1
        with:
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
          api-key: ${{ secrets.VELA_API_KEY }}
```

Without the key the deploy runs exactly the same; it just is not logged.

## Preview deployments for pull requests

With the project linked and an API key in place, the same step deploys every
pull request as its own copy of the app — own database, own process, own
hostname — and removes it when the pull request closes. Nothing else changes
in the workflow except which events run it:

```yaml
name: Deploy

on:
  push:
    branches: [main]
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
  contents: read
  pull-requests: write

concurrency:
  group: vela-${{ github.head_ref || github.ref_name }}
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: velastack/action@v1
        with:
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
          api-key: ${{ secrets.VELA_API_KEY }}
        env:
          POCKETBASE_SUPERUSER_EMAIL: ci@example.com
          POCKETBASE_SUPERUSER_PASSWORD: ci-build-only-password
```

`vela enable ci --previews` writes this workflow.

A push to `main` deploys production, as before. A pull request deploys
`preview:<branch>`, which lands at `<project>--<branch>.velastack.app` and is
posted to the pull request as a comment that updates on every push. Closing
the pull request removes the preview from the server, database and uploads
included (the CLI keeps a snapshot in the server's trash for two weeks), and
retires the hostname.

The default `action: auto` only ever removes previews. A workflow that sets
`target` to production or a named environment and still runs on `closed`
events fails on that event rather than removing the target; to remove one of
those from CI on purpose, set `action: destroy` and `confirm-name` to the
app's name.

A push that is still being tested when its pull request closes does not bring
the preview back. The `closed` run skips any jobs that gate the deploy, so it
usually removes the preview first, and a `concurrency` group only queues jobs
that have started. To cover that, the action reads the pull request's state
before deploying a preview and skips the deploy if it has closed. The CLI also
checks on the server, in releases after vela 0.15.0: a deploy that began before
its target was removed is dropped there, even when the close happens
mid-build. Either way the step succeeds with `mode: skipped`, and the pull
request comment is left as the cleanup wrote it.

Previews go to the server recorded for previews in `.vela/project.json`
(`targets.preview.server`), or to production's when there is none. A preview
is first built against a throwaway database on the runner, which is what the
placeholder `POCKETBASE_SUPERUSER_*` values are for.

Previews never inherit `domain`: that is production's. To serve previews on
your own domain as well, add a preview base on the project's Domains page on
velastack.dev and point `*.preview.example.com` at the server's origin name.

Two things to know about `velastack.app` hostnames: requests pass through
Cloudflare, so uploads are capped at 100 MB and a quiet realtime connection
reconnects after about 100 seconds. A custom domain has neither limit.

Each preview is a full instance, so a server hosts as many previews as it has
memory for. Nothing is pruned automatically yet; close pull requests to free
them.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `server` | | from `.vela/project.json` | SSH target, as `user@host` or `host`. Read from the target's entry in `.vela/project.json` when unset |
| `ssh-key` | yes | | Private key with access to the server |
| `ssh-port` | | `22` | Port, when the server does not listen on 22 |
| `known-hosts` | | | Contents for `known_hosts`. Without it the host key is fetched on first connect |
| `target` | | `production` | Which copy of the app to deploy: `production` (the `prod` entry in `.vela/project.json`), or a name you chose such as `staging`. On a pull request, defaults to a preview of its branch |
| `environment` | | | Deprecated name for `target`, still honoured when `target` is unset |
| `domain` | | from `.vela/project.json` | Hostname(s) to serve on, comma separated. Only needed to change it |
| `project` | | | Override the project name |
| `health-path` | | `/` | Path the health check requests |
| `remote-db` | | on once deployed | Build against the server's database. Left unset, on for a target that has been deployed to and off for its first deploy — see below |
| `working-directory` | | `.` | Directory holding the app |
| `node-version` | | `.nvmrc` or `.node-version`, else `26` | Node.js version to build with |
| `install` | | `true` | Install dependencies first: `npm ci`, or `pnpm install --frozen-lockfile` when only a `pnpm-lock.yaml` is committed |
| `vela-version` | | | Version of the CLI to run. Defaults to the one the project pins |
| `api-key` | | | velastack.dev API key. With it, every deploy is recorded on the linked project and previews get a hostname |
| `action` | | `auto` | `deploy`, `destroy`, or `auto`: deploy, except on a closed pull request, which removes the preview. `auto` never removes anything but a preview |
| `confirm-name` | | | The app's name, required when `action: destroy` targets production or a named environment. Not needed for previews |
| `comment` | | `true` | Keep one comment on the pull request up to date with the preview URL |
| `github-token` | | workflow token | Token the comment is posted with, and the pull request's state is read with before a preview deploys; needs `pull-requests: write` |

## Outputs

| Output | Description |
| --- | --- |
| `release` | Identifier of the release that was activated |
| `url` | URL the app is served on |
| `hostnames` | Every hostname the target is served on, comma separated |
| `target` | The target that was deployed or removed |
| `mode` | `deploy`, `destroy`, or `skipped` when a preview was not deployed because its pull request had closed |

## Pages that prerender from data

A prerendered page is rendered once, at build time, against whatever database the build can see. On a runner that is an empty throwaway database, so those pages come out full of defaults — a site name of "Acme", empty lists, missing copy — even though the running app is fine.

So once a target has been deployed to, the build renders against the database it is being deployed to, tunnelled over the same SSH connection. That is the default, and there is nothing to set. The superuser credentials come off the server, so no new secrets go into CI.

The first deploy of a target has no database to read yet, and builds against a throwaway one on the runner. That includes the first deploy of each pull request preview; later pushes to the same pull request build against the preview's own database. To build against a throwaway database always, so that a build never reads production data, turn it off:

```yaml
      - uses: velastack/action@v1
        with:
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
          remote-db: false
```

`remote-db: true` insists on the deployed database, and fails the run when the target has none yet.

## Secrets and environment

Production environment variables live on your server, not in this action and not in the release. Set them once with the CLI:

```sh
vela env set STRIPE_SECRET_KEY
vela env import .env.production
vela env list
```

A deploy never reads, uploads, or overwrites them.

Anything the **build** needs — as opposed to the running app — belongs in the workflow's `env`, because it has to exist on the runner: a variable the app reads at build time, for instance.

### PocketBase superuser credentials

The real ones never go in the workflow, and never in GitHub secrets. The server created them on the first deploy and keeps them in the target's environment; a build that renders against the deployed database (the default, see above) reads them from there over SSH.

What a project with a PocketBase backend does need on the runner is a pair of **placeholders**:

```yaml
      - uses: velastack/action@v1
        with:
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
        env:
          POCKETBASE_SUPERUSER_EMAIL: ci@example.com
          POCKETBASE_SUPERUSER_PASSWORD: ci-build-only-password
```

They are the login for a throwaway database that exists only on the runner, for the builds that use one: a target's first deploy from CI, the first deploy of each pull request preview, and any build with `remote-db: false`. A build against the deployed database replaces them with the server's own for the duration of the build. Any values work (the password needs ten characters), they open nothing, and they never leave the job. The CLI still checks that both are set before it deploys a project with a backend, so keep them in the workflow even when every build uses the deployed database. A project without a backend needs neither.

## Pinning the host key

By default the action trusts the server's host key the first time it connects. To pin it instead, capture it once:

```sh
ssh-keyscan -H your-server
```

and pass the output as the `known-hosts` input, from a secret or a variable.

## Requirements

- The app builds with `@sveltejs/adapter-node`.
- `.vela/project.json` is committed — it carries the app id the server keys everything on.
- A `package-lock.json` (npm) or a `pnpm-lock.yaml` (pnpm) is committed.

## License

MIT
