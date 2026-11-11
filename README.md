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

It also manages the companion `ipmievd` daemon, whose name can be
customized with the `ipmievd_service_name` parameter.

## Usage

### Reference

See [REFERENCE](REFERENCE.md)

### Examples

```puppet
  include ipmi
```

Create a user with admin privileges (default):

```puppet
  ipmi::user { 'newuser1':
    user     => 'newuser1',
    password => 'password1',
    user_id  => 4,
  }
```

Create a user with operator privileges:

```puppet
  ipmi::user { 'newuser2':
    user     => 'newuser2',
    password => 'password2',
    priv     => 3,
    user_id  => 5,
  }
```

Create a user with user privileges on a specific channel:

```puppet
  ipmi::user { 'newuser3':
    user     => 'newuser3',
    password => 'password3',
    priv     => 2,
    user_id  => 6,
    channel  => 3,
  }
```

Create a user and remove any instance with the wrong `user_id`:

```puppet
  ipmi::user { 'newuser1':
    user     => 'newuser1',
    password => 'password1',
    user_id  => 4,
    purge_id_mismatch => true,
  }
```

Configure a static ip on IPMI lan channel 1:

```puppet
  ipmi::network { 'lan1':
    type        => 'static',
    ip          => '192.168.1.10',
    netmask     => '255.255.255.0',
    gateway     => '192.168.1.1',
  }
```

Configure IPMI lan channel 1 to DHCP:

```puppet
  ipmi::network { 'dhcp': }
```

Configure IPMI snmp string on lan channel 1:

```puppet
 ipmi::snmp { 'lan1':
   snmp        => 'secret',
   lan_channel => 1,
 }
```

### Classes

#### `ipmi`

```puppet
  # defaults
  class { 'ipmi':
    service_ensure         => 'running', # default is 'running'
    ipmievd_service_ensure => 'running', # default is 'stopped'
    watchdog               => true,      # default is false
    service_manage         => false,     # default is true
  }
```

When `service_manage` is set to `false`, the `ipmi` service is not managed
by the module; it is left to the administrator or an external tooling
system to start and stop. The companion `ipmievd` daemon and the rest of
the module continue to behave normally.

#### The IPMI hardware watchdog

When `watchdog => true` the module loads the `ipmi_watchdog` kernel module,
now and at boot (via `modules-load.d`), and sets `IPMI_WATCHDOG=yes` in the
OpenIPMI service config, which makes that service load the module too. The
module provides `/dev/watchdog`. Loading it does not start the BMC timer: the
timer runs once something opens `/dev/watchdog`, or if the module is given the
`start_now=1` option.

- `watchdog_timeout` sets the module `timeout` option, in seconds. The default,
  `0`, writes no option and leaves the driver default (10 seconds).
- `watchdog_module_options` adds any other modprobe option. Setting `timeout`
  here as well as a non-zero `watchdog_timeout` is an error unless the two
  values match.
- `watchdog_manage_module => false` skips the module load and its options, for
  hosts where `/dev/watchdog` already exists. `watchdog_timeout` and
  `watchdog_module_options` then have no effect.

Module options only apply the next time the module is loaded, usually after a
reboot. Setting `watchdog => false` does not remove module configuration
written earlier.

```puppet
  class { 'ipmi':
    watchdog                => true,
    watchdog_timeout        => 60,
    watchdog_module_options => { 'action' => 'power_cycle' },
  }
```

### Defined Resources

#### `ipmi::user`

```puppet
  # defaults
  ipmi::user { 'newuser':
    user     => 'root',
    priv     => 4,           # Administrator
    user_id  => 3,
  }
```

#### `ipmi::network`

```puppet
  # defaults
  ipmi::network { 'lan1':
    type        => 'dhcp',
    ip          => '0.0.0.0',
    netmask     => '255.255.255.0',
    gateway     => '0.0.0.0',
    lan_channel => 1,
  }
```

#### `ipmi::snmp`

```puppet
  # defaults
  ipmi::snmp { 'lan1':
    snmp        => 'public',
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
