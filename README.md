# @velastack/action

Deploy a [VelaStack](https://velastack.dev) app to your own server from GitHub Actions.

The action builds the app on the runner and hands it to `vela deploy` over SSH — the same command you run locally, so a deploy from CI and a deploy from your laptop do exactly the same thing.

## Before you start

The server has to be prepared once, from your machine:

```sh
vela provision root@your-server
```

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
| `working-directory` | | `.` | Directory holding the app |
| `node-version` | | `22` | Node.js version to build with |
| `install` | | `true` | Run `npm ci` first |
| `vela-version` | | | Version of the CLI to run. Defaults to the one the project pins |

## Outputs

| Output | Description |
| --- | --- |
| `release` | Identifier of the release that was activated |
| `url` | URL the app is served on |

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
