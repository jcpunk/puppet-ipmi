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
#   Controls whether the IPMI watchdog is enabled. When `true`, the
#   `ipmi_watchdog` kernel module is loaded (see `watchdog_manage_module`) and
#   `IPMI_WATCHDOG` is set to `yes`. When `false`, `IPMI_WATCHDOG` is set to
#   `no` and the kernel module is not managed; module configuration written
#   while it was `true` is left in place.
# @param snmps
#   `ipmi::snmp` resources to create.
# @param users
#   `ipmi::user` resources to create.
# @param networks
#   `ipmi::network` resources to create.
# @param service_manage
#   Controls whether the `ipmi` service is managed. When `false`, the
#   `service` resource is not declared and the service is left unmanaged
#   (handled by the administrator or an external tooling system).
# @param watchdog_manage_module
#   Whether to load the `ipmi_watchdog` kernel module, and write its modprobe
#   options, when `watchdog` is `true`. Set `false` when `/dev/watchdog`
#   already exists, for example because the module is built in or loaded by
#   other tooling. `watchdog_timeout` and `watchdog_module_options` have no
#   effect when this is `false`.
# @param watchdog_timeout
#   Watchdog timeout in seconds, passed to the `ipmi_watchdog` module as its
#   `timeout` option. `0` (the default, matching systemd's default of off)
#   writes no option and leaves the driver default (10 seconds) in place.
# @param watchdog_module_options
#   Extra `ipmi_watchdog` modprobe options, for example `{ 'action' => 'power_cycle' }`.
#   A `timeout` key must not disagree with a non-zero `watchdog_timeout`.
# @param default_channel
#   Default channel to use for IPMI commands.
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
  Boolean $service_manage = true,
  Boolean $watchdog_manage_module = true,
  Integer[0] $watchdog_timeout = 0,
  Hash[String[1], Scalar] $watchdog_module_options = {},
  Integer[0] $default_channel = Integer(pick(fact('ipmi.default.channel'), 1)),
) {
  contain ipmi::install
  contain ipmi::config
  contain ipmi::service

  Class['ipmi::install']
  ~> Class['ipmi::config']
  ~> Class['ipmi::service']

  if $snmps {
    create_resources('ipmi::snmp', $snmps)
  }

  if $users {
    create_resources('ipmi::user', $users)
  }

  if $networks {
    create_resources('ipmi::network', $networks)
  }
}
