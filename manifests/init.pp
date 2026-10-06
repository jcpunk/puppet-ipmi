#
# @summary Manages OpenIPMI
#
# @param packages
#   List of packages to install.
# @param config_file
#   Absolute path to the ipmi service config file.
# @param service_name
#   Name of IPMI service.
# @param service_ensure
#   Controls the state of the `ipmi` service. Possible values: `running`, `stopped`
# @param ipmievd_service_name
#   Name of ipmievd service.
# @param ipmievd_service_ensure
#   Controls the state of the `ipmievd` service. Possible values: `running`, `stopped`
# @param watchdog
#   Controls whether the IPMI watchdog is enabled.
# @param snmps
#   `ipmi_snmp` resources to create.
# @param users
#   `ipmi_user` resources to create.
# @param networks
#   `ipmi_network` resources to create.
# @param default_channel
#   Optional default IPMI channel (1-15) to use for resources that do not
#   specify one.  When unset, each resource uses its own default (an integer
#   title, the ipmi.default.channel fact, or 1).
#
class ipmi (
  Array[String] $packages,
  Stdlib::Absolutepath $config_file,
  String $service_name,
  String $ipmievd_service_name,
  Variant[Stdlib::Ensure::Service, String[0]] $service_ensure,
  Stdlib::Ensure::Service $ipmievd_service_ensure,
  Boolean $watchdog,
  Optional[Hash] $snmps,
  Optional[Hash] $users,
  Optional[Hash] $networks,
  Optional[Integer[1, 15]] $default_channel = undef,
) {
  $real_service_ensure = $service_ensure ? {
    'running' => 'running',
    default   => 'stopped',
  }

  $enable_ipmi = $real_service_ensure ? {
    'running' => true,
    'stopped' => false,
  }

  $enable_ipmievd = $ipmievd_service_ensure ? {
    'running' => true,
    'stopped' => false,
  }

  contain ipmi::install
  contain ipmi::config

  class { 'ipmi::service::ipmi':
    ensure            => $real_service_ensure,
    enable            => $enable_ipmi,
    ipmi_service_name => $service_name,
  }

  class { 'ipmi::service::ipmievd':
    ensure => $ipmievd_service_ensure,
    enable => $enable_ipmievd,
  }

  Class['ipmi::install']
  ~> Class['ipmi::config']
  ~> Class['ipmi::service::ipmi']
  ~> Class['ipmi::service::ipmievd']

  # Unset: the types derive the channel themselves (integer title, else the
  # ipmi.default.channel fact).
  $user_defaults = $default_channel ? {
    undef   => {},
    default => { 'channel' => $default_channel },
  }
  $lan_defaults = $default_channel ? {
    undef   => {},
    default => { 'lan_channel' => $default_channel },
  }

  if $users {
    $users.each |$title, $params| {
      ipmi_user { $title:
        * => $user_defaults + $params,
      }
      Class['ipmi::install'] -> Ipmi_user[$title]
    }
  }

  if $networks {
    $networks.each |$title, $params| {
      ipmi_network { $title:
        * => $lan_defaults + $params,
      }
      Class['ipmi::install'] -> Ipmi_network[$title]
    }
  }

  if $snmps {
    $snmps.each |$title, $params| {
      ipmi_snmp { $title:
        * => $lan_defaults + $params,
      }
      Class['ipmi::install'] -> Ipmi_snmp[$title]
    }
  }
}
