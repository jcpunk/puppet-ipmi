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
#   Default IPMI channel (1-15) to use for resources that do not specify one.
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
  Integer[1, 15] $default_channel = Integer(fact('ipmi.default.channel') or 1),
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

  if $users {
    $users.each |$title, $params| {
      ipmi_user { $title:
        *       => $params - 'channel',
        channel => pick($params['channel'], $default_channel),
      }
    }
  }

  if $networks {
    $networks.each |$title, $params| {
      ipmi_network { $title:
        *           => $params - 'lan_channel',
        lan_channel => pick($params['lan_channel'], $default_channel),
      }
    }
  }

  if $snmps {
    $snmps.each |$title, $params| {
      ipmi_snmp { $title:
        *           => $params - 'lan_channel',
        lan_channel => pick($params['lan_channel'], $default_channel),
      }
    }
  }

  Class['ipmi::install'] -> Ipmi_user <| |>
  Class['ipmi::install'] -> Ipmi_network <| |>
  Class['ipmi::install'] -> Ipmi_snmp <| |>
}
