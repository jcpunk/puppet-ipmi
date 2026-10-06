# Puppet ipmi Module

[![CI](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/ci.yml/badge.svg)](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/ci.yml)
[![markdownlint](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/markdownlint.yaml/badge.svg)](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/markdownlint.yaml)
[![shellcheck](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/shellcheck.yaml/badge.svg)](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/shellcheck.yaml)
[![yamllint](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/yamllint.yaml/badge.svg)](https://github.com/jhoblitt/puppet-ipmi/actions/workflows/yamllint.yaml)

## Table of Contents

1. [Overview](#overview)
1. [Description](#description)
1. [Usage](#usage)
  * [Examples](#examples)
  * [Classes](#classes)
1. [Additional Facts](#additional-facts)
1. [Limitations](#limitations)
1. [Versioning](#versioning)
1. [Support](#support)
1. [Contributing](#contributing)
1. [See Also](#see-also)

## Overview

Manages the OpenIPMI package

## Description

Installs the [OpemIPMI](http://openipmi.sourceforge.net/) package,
provides IPMI facts in a format compatible with
[The Foreman](https://www.theforeman.org)'s
[BMC features](https://www.theforeman.org/manuals/latest/index.html#4.3.3BMC)
and enables the `ipmi` service. The latter loads the kernel drivers
needed for communicating with the BMC from user space.

## Usage

### Reference

See [REFERENCE](REFERENCE.md)

### Examples

```puppet
  include ipmi
```

Create a user with admin privileges in any slot (default):

```puppet
  ipmi_user { 'newuser1':
    password => 'password1',
  }
```

Create a user with operator privileges:

```puppet
  ipmi_user { 'operator user: newuser2':
    username => 'newuser2',
    password => 'password2',
    priv     => 3,
    user_id  => 5,
  }
```

Create a user with user privileges on a specific channel:

```puppet
  ipmi_user { 'newuser3':
    password => 'password3',
    priv     => 2,
    user_id  => 6,
    channel  => 3,
  }
```

Create a user and remove any instance with the wrong `user_id`:
```puppet
  ipmi_user { 'newuser1':
    password => 'password1',
    user_id  => 4,
    purge_id_mismatch => true,
  }
```


Configure a static ip on IPMI lan channel 1:

```puppet
  ipmi_network { 'lan1':
    type        => 'static',
    ip          => '192.168.1.10',
    netmask     => '255.255.255.0',
    gateway     => '192.168.1.1',
    lan_channel => 1,
  }
```

Configure IPMI lan channel 1 to DHCP:

```puppet
  ipmi_network { 'lan1 DHCP':
    type        => 'dhcp',
    lan_channel => 1,
  }
```

Configure IPMI snmp string on lan channel 1:

```puppet
  ipmi_snmp { 'lan1':
    community   => 'secret',
    lan_channel => 1,
  }
```

### Backend selection

`ipmitool` is the supported backend and the default on Linux. The
`freeipmi` providers are experimental. To force a specific backend, set
the provider on the resource:

```puppet
  ipmi_user { 'newuser1':
    password => 'password1',
    provider => 'freeipmi',
  }
```

NOTE: the `freeipmi` backend is **EXPERIMENTAL** and may not work in all cases!

### Classes

#### `ipmi`

```puppet
  # defaults
  class { 'ipmi':
    service_ensure         => 'running', # default is 'running'
    ipmievd_service_ensure => 'running', # default is 'stopped'
    watchdog               => true,      # default is false
  }
```

When `users`, `networks`, or `snmps` are passed as class parameters, the
`ipmi` class declares the corresponding native resources and injects the
`default_channel` value for any resource that does not specify a channel.
`ipmi_network` and `ipmi_snmp` reject catalogs where two resources target
the same LAN channel, preventing them from fighting on every run.

### Native Resources

The public API consists of the native Puppet types `ipmi_user`,
`ipmi_network`, and `ipmi_snmp`. The previous wrapper defined types
(`ipmi::user`, `ipmi::network`, `ipmi::snmp`) have been removed.

When upgrading from 8.x or earlier:
- `ipmi_user` takes `username`, not `user`.
- `ipmi_user`'s `user_id` now defaults to `'auto'`.
- `ipmi::snmps` entries and `ipmi_snmp` take `community`, not `snmp`.
- `ip`, `netmask` or `gateway` together with `type => 'dhcp'` is rejected,
  and the error fails the whole agent run.
- A static `ipmi_network` no longer defaults `netmask` to `255.255.255.0`
  or `gateway` to `0.0.0.0`; unset ones keep whatever the BMC holds.
- `ipmi::default_channel` applies only to resources declared through the
  `ipmi` class.
- The `ipmi_user`'s username now defaults to the `namevar` rather than `root`.

#### `ipmi_user`

```puppet
  # defaults
  ipmi_user { 'newuser':
    priv     => 4,           # Administrator
    user_id  => 'auto',      # auto-select a slot
    channel  => 1,
  }
```

When `enable => false`, the BMC user slot is disabled and its privilege is
forced to `NO ACCESS` regardless of the `priv` value.  This makes disabled
resources suitable for reserving a slot ID without granting login access.
`purge_id_mismatch => true` will also remove duplicate usernames from other
slots when the resource is disabled.

#### `ipmi_network`

```puppet
  ipmi_network { 'lan1':
    type        => 'dhcp',
    lan_channel => 1,
  }
```

#### `ipmi_snmp`

```puppet
  ipmi_snmp { 'lan1':
    community   => 'public',
    lan_channel => 1,
  }
```

## Additional Facts

This module provides additional facts for Facter with the following
formats:

### Structured Format

```text
ipmi => {
  default => {
    channel => 1,
    gateway => 192.168.10.1,
    ipaddress => 192.168.10.201,
    ipaddress_source => Static Address,
    macaddress => 00:30:48:c9:64:2a,
    subnet_mask => 255.255.255.0,
    users => {
      1 => {
        id => 1,
        name => '',
        privilege => 'NO ACCESS',
      },
      2 => {
        id => 2,
        name => 'admin',
        privilege => 'ADMINISTRATOR',
      }
    },
  },
  1 => {
    channel => 1,
    gateway => 192.168.10.1,
    ipaddress => 192.168.10.201,
    ipaddress_source => Static Address,
    macaddress => 00:30:48:c9:64:2a,
    subnet_mask => 255.255.255.0,
    users => {
      1 => {
        id => 1,
        name => '',
        privilege => 'NO ACCESS',
      },
      2 => {
        id => 2,
        name => 'admin',
        privilege => 'ADMINISTRATOR',
      }
    },
  },
}
```

### DEPRECATED Flat Format

```text
ipmi1_gateway => 192.168.10.1
ipmi1_ipaddress => 192.168.10.201
ipmi1_ipaddress_source => Static Address
ipmi1_macaddress => 00:30:48:c9:64:2a
ipmi1_subnet_mask => 255.255.255.0
```

where the 1 in `ipmi1` corresponds to the channel according to
`ipmitool lan print`.

Additionally for compatibility with The Foreman, the first IPMI
interface (i.e. the one from `ipmi lan print 1`) gets all facts
repeated as just `ipmi_foo`:

```text
ipmi_gateway => 192.168.10.1
ipmi_ipaddress => 192.168.10.201
ipmi_ipaddress_source => Static Address
ipmi_macaddress => 00:30:48:c9:64:2a
ipmi_subnet_mask => 255.255.255.0
```

## Limitations

At present, only support for RedHat and Debian distributions
has been implemented.

Adding other Linux distrubtions should be trivial.

## Versioning

This module is versioned according to the [Semantic Versioning
2.0.0](http://semver.org/spec/v2.0.0.html) specification.

## Support

Please log tickets and issues at
[github](https://github.com/jhoblitt/puppet-ipmi/issues)

## Contributing

1. Fork it on github
1. Make a local clone of your fork
1. Create a topic branch.  Eg, `feature/mousetrap`
1. Make/commit changes
  * Commit messages should be in [imperative tense](http://git-scm.com/book/ch5-2.html)
  * Check that linter warnings or errors are not introduced - `bundle exec rake lint`
  * Check that `Rspec-puppet` unit tests are not broken and coverage is added for new
    features - `bundle exec rake spec`
  * Documentation of API/features is updated as appropriate in the README
  * If present, `beaker` acceptance tests should be run and potentially
    updated - `bundle exec rake beaker`
1. When the feature is complete, rebase / squash the branch history as
   necessary to remove "fix typo", "oops", "whitespace" and other trivial commits
1. Push the topic branch to github
1. Open a Pull Request (PR) from the *topic branch* onto parent repo's `master` branch

## See Also

* [OpenIPMI](http://openipmi.sourceforge.net/)
