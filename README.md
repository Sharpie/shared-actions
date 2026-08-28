# Shared Actions

This repo contains github actions that can be shared across the org.
The original impetus was for syncing actions to keep the mirrors updated,
but I'm sure that more uses will crop up soon.

## Actions:

### Syncing / mirroring actions

- These actions automatically sync an upstream repository of the same name
  once a day.
- The upstream code is visible as branches and tags.
- The `plumbing` branch must be the default branch and contain the calling
  sync workflow and documentation.
- Fetched upstream branches are also published below `backup/<date>/`.

The two actions do things a little bit differently.

- `/.github/workflows/mirror.yml`
  - Designed to be used in a template repository that clones and mirrors an
    upstream repository based on its name.
  - To use it, create a new repository with the appropriate name.
    For example, `OpenVoxProject/foo` will mirror `puppetlabs/foo`.
  - This one does not work well because GitHub restricts workflows from
    creating or modifying workflow files.
  - Workflow files are therefore deleted with each sync, making it easy for
    the repository to become unsynchronized.
- `/.github/workflows/sync.yml`
  - This workflow relies on the user having cloned each repository and set up
    its plumbing branch.
  - It uses `git fetch` and `git push` to synchronize branches and tags.

An invoking repository can schedule the reusable sync workflow like this:

```yaml
name: Sync any source updates

on:
  workflow_dispatch:
  schedule:
  - cron: '17 2 * * *'

permissions:
  contents: write

jobs:
  update:
    uses: OpenVoxProject/shared-actions/.github/workflows/sync.yml@main
    secrets: inherit
```

The caller must live on the `plumbing` default branch.
By default, the reusable workflow mirrors the repository of the same name
from the `puppetlabs` organization.
Set the `upstream_owner` input if a repository has a different upstream owner.
The caller's `GITHUB_TOKEN` is used unless an optional `WORKFLOW_TOKEN` secret
is inherited or explicitly passed.
That token needs permission to force-push the mirrored branches and tags under
the repository's branch and tag protection rules.
The workflow uses each repository's GitHub `updatedAt` value to skip a run when
the mirror is at least as recent as its upstream.

### Beaker Acceptance action:

The `/.github/workflows/beaker_acceptance.yml` is a reusable workflow
for [Beaker](https://github.com/voxpupuli/beaker) acceptance of
OpenVox projects.

It:

* checks out the given project-name@ref
* runs the [nested_vms](https://github.com/jpartlow/nested_vms) action
  to generate a set of test target vms using the
  [kvm_automation_tooling](https://github.com/jpartlow/kvm_automation_tooling)
  Bolt module.
* installs the selected openvox components, either from collections
  served from the apt and yum voxpupuli repositories, or from the
  artifacts-url server for pre-release builds.
* generates a Beaker hosts.yaml from the test target inventory
* configures and executes Beaker with the given beaker-options,
  acceptance-pre-suite and acceptance-tests.

#### Usage

Some example usages can be found in the openvox, openvox-agent and
openvox-server repositories in the `.github/workflows` directory.

See [beaker_acceptance.yml](.github/workflows/beaker_acceptance.yml)
for parameter details.

#### Arm64 Support

You can run the `beaker_acceptance` workflow on arm64 guests in gha by
setting `guest_arch` to `arm64`. Currently though this has serious
limitations due to the lack of kvm support on the gha arm64 runners.

* https://github.com/actions/runner-images/issues/14062

Consequently, the kvm_automation_tooling module runs the arm64 guests
emulated with qemu instead, and they are *very* slow. Many of the
suites hit the gha 6 hour job timeout if run without special
provisions.

The workflow makes several adjustments when it detects that it will be
running the guests in qemu.

For openvox it reduces the os platforms to DEFAULT_OS_ARM64_PLATFORMS
and adds acceptance-shard-tags to the the job matrix to limit the
number of tests executed per runner. With these two concessions, the
openvox suite completes in about 4 hours (at least on the couple of
platforms in that default matrix).

The openvox-agent suite runs normally, albeit slowly. Except that
rocky10 fails currently because `which` is not installed on the arm64
image for unknown reasons, and this breaks the
openvox/packaging/acceptance/tests/validate_vendored_ruby.rb test.

For openvox-server, all the ubuntu platforms are removed from the
matrix, as they are by far the slowest. Alma9/rocky9 are known to
complete successfully at the moment. The other platforms have
scattered but consistent timing failures, mostly related to ssh?
Except el10 which has a postgresql repo gpg key issue that I did not
run down.

For openvoxdb, ubuntu platforms are removed as well, but no work has
been done in the openvoxdb suite to accomodate timeouts and such, and
it generally fails in the presuite.

In general, the workflow adds additional timeouts to the .beaker.yml
configuration, though again, those are only helpful if the beaker
suite being run makes use of them. Currently openvox and
openvox-server suites do, but openvoxdb does not.

I don't know why ubuntu qemu arm64 runs 2-4x slower than el/debian,
but it does and was consistently hitting the 6 hour gha job timeout on
all the suites except openvox-agent, which is why it's excluded
everywhere but there.
