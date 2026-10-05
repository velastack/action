# @velastack/action

Deploy a [VelaStack](https://velastack.dev) app to your own server from GitHub Actions.

The action builds the app on the runner and hands it to `vela deploy` over SSH — the same command you run locally, so a deploy from CI and a deploy from your laptop do exactly the same thing.

## Before you start

The server has to be prepared once, and the app deployed once, from your machine:

```sh
vela provision root@your-server
vela deploy --server root@your-server --domain example.com
git add .vela/project.json && git commit -m "Add the vela project id"
```

That first deploy is what gives the project its permanent app id. The action
refuses to run until `.vela/project.json` is committed: a runner that finds no
id mints a new one, and since its checkout is thrown away at the end of the job,
every deploy would land as a brand new app and orphan the last one on the
server.

Then give the action a way in:

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
          server: root@your-server
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
          domain: example.com
```

That is the whole thing. The action installs dependencies, builds, uploads a release, runs migrations, restarts the services and health-checks the result. A deploy that fails its health check puts the previous release back and fails the job.

Use a `concurrency` group so two pushes cannot deploy over each other.

## Recording deploys on velastack.dev

A project that has been `vela link`ed can have every deploy from CI show up on
its dashboard: who deployed, which commit, which target, where it landed. Create
an API key at <https://velastack.dev/api-keys/new>, store it as a repository
secret, and pass it in:

```yaml
      - uses: velastack/action@v1
        with:
          server: root@your-server
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
          server: root@your-server
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
          api-key: ${{ secrets.VELA_API_KEY }}
          domain: example.com
```

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
| `server` | yes | | SSH target, as `user@host` or `host` |
| `ssh-key` | yes | | Private key with access to the server |
| `ssh-port` | | `22` | Port, when the server does not listen on 22 |
| `known-hosts` | | | Contents for `known_hosts`. Without it the host key is fetched on first connect |
| `environment` | | `prod` | Environment to deploy |
| `domain` | | | Hostname(s) to serve on, comma separated |
| `project` | | | Override the project name |
| `health-path` | | `/` | Path the health check requests |
| `remote-db` | | `false` | Build against the server's database — see below |
| `working-directory` | | `.` | Directory holding the app |
| `node-version` | | `.nvmrc`, else `24` | Node.js version to build with |
| `install` | | `true` | Run `npm ci` first |
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

Set `remote-db: true` and the build renders against the database it is being deployed to, tunnelled over the same SSH connection. The superuser credentials come off the server, so no new secrets go into CI.

```yaml
      - uses: velastack/action@v1
        with:
          server: root@your-server
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
          remote-db: true
```

It is off by default because it lets a build read production data, which is only what you want when you know your pages depend on it. It also needs the environment to have been deployed at least once.

## Secrets and environment

Production environment variables live on your server, not in this action and not in the release. Set them once with the CLI:

```sh
vela env set STRIPE_SECRET_KEY
vela env import .env.production
vela env list
```

A deploy never reads, uploads, or overwrites them.

Anything the **build** needs — as opposed to the running app — belongs in the workflow, because it has to exist on the runner:

```yaml
      - uses: velastack/action@v1
        env:
          POCKETBASE_SUPERUSER_EMAIL: ${{ secrets.POCKETBASE_SUPERUSER_EMAIL }}
          POCKETBASE_SUPERUSER_PASSWORD: ${{ secrets.POCKETBASE_SUPERUSER_PASSWORD }}
        with:
          server: root@your-server
          ssh-key: ${{ secrets.SSH_PRIVATE_KEY }}
```

## Pinning the host key

By default the action trusts the server's host key the first time it connects. To pin it instead, capture it once:

```sh
ssh-keyscan -H your-server
```

and pass the output as the `known-hosts` input, from a secret or a variable.

## Requirements

- The app builds with `@sveltejs/adapter-node`.
- `.vela/project.json` is committed — it carries the app id the server keys everything on.
- The repository uses npm (a `package-lock.json` is present).

## License

MIT
