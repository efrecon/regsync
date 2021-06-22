# Docker Registry Sync

This project is able to selectively synchronise images from a source Docker
registry to a destination registry. Synchronisation is able to restrict to a
subset of the existing images at the source, a subset of the tags or their age.
Images can also be renamed on their way to the destination, so as to be
re-rooted under a top project name, for example.

When copying images, [`sync.sh`](./sync.sh) will use the local Docker storage to
pull, re-tag and push. Images that did not already exist at the local daemon
prior to pulling will automatically be removed to avoid using too much disk
space at the local host daemon.

## Requirements

[`sync.sh`](./sync.sh) is implemented in POSIX shell. This project uses git
[submodules] to satisfy its [dependencies][mg.sh], you should clone with the
`--recurse` or catch-up. The implementation has the following requirements:

1. A local Docker installation, and the ability for the current user to run the
   `docker` client without `sudo`. Note, however, that a [Docker](#docker) image
   to run the project is available.
2. A local installation of [reg] is preferred. When it cannot be found, the
   implementation will revert to running `reg` through Docker, which is much
   slower. A compatible version of `reg` is present in the [Docker](#docker)
   image.
3. A local installation of [jq] is preferred. When it cannot be found, the
   implementation will revert to running `jq` through Docker, which is much
   slower. `jq` is present in the [Docker](#docker) image.

  [submodules]: https://git-scm.com/book/en/v2/Git-Tools-Submodules
  [mg.sh]: https://github.com/Mitigram/mg.sh
  [reg]: https://github.com/genuinetools/reg
  [jq]: https://github.com/stedolan/jq

## Usage

[`sync.sh`](./sync.sh) provides on-line help at the command-line. Provided that
your installation meets the [requirements](#requirements), running the following
command should print a documentation summary.

```shell
./sync.sh --help
```

## Environment Variables

The behaviour of `sync.sh` can be driven by a series of environment variables,
all starting with the prefix `SYNC_`. Command-line options, when present, will
override the value of any environment variable. At the time of writing, these
variables are undocumented, but their meaning is documented at the beginning of
[`sync.sh`](./sync.sh).

## Docker

The synchronisation utility also comes as a Docker [image] so that it can be run
from a container. When running from a container, you would need to map your
.docker hidden directory onto the one of the root user in the container with
read-only access, as in the dummy command example below. You will also have to
pass the Docker socket to the container so that it can interact with the local
Docker daemon. You should understand the risk of passing your credentials and
Docker socket to this script and the underlying [reg] tool.

```shell
docker run \
  -it \
  --rm \
  -v ${HOME}/.docker:/root/.docker:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  mitigram/regsync \
    --help
```

  [image]: https://hub.docker.com/r/mitigram/regsync
