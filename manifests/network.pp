# == Defined resource type: ipmi::network
#

define ipmi::network (
  $ip = '0.0.0.0',
  $netmask = '255.255.255.0',
  $gateway = '0.0.0.0',
  $type = 'dhcp',
  $lan_channel = 1,
  $interface_type = 'dedicated',
)
{
  require ::ipmi

  validate_string($ip,$netmask,$gateway,$type)
  validate_integer($lan_channel)
  validate_re($type, '^dhcp$|^static$', 'Network type must be either dhcp or static')
  validate_string($interface_type)

  case $interface_type {
    'dedicated': {
      $interface_code = 0
    }
    'shared': {
      $interface_code = 1
    }
    'failover': {
      $interface_code = 2
    }
    default: {
      fail('Network interface type must be one of: dedicated, shared, or failover')
    }
  }

  $interface_type_raw_command_code = '0x30 0x70 0x0c'
  exec { "ipmi_set_interface_type_${lan_channel}":
    command => "/usr/bin/ipmitool raw ${interface_type_raw_command_code} 1 ${interface_code}",
    onlyif  => "/usr/bin/test $(/usr/bin/ipmitool raw ${interface_type_raw_command_code} 0) -ne ${interface_code}",
  }

  if $type == 'dhcp' {

    exec { "ipmi_set_dhcp_${lan_channel}":
      command => "/usr/bin/ipmitool lan set ${lan_channel} ipsrc dhcp",
      onlyif  => "/usr/bin/test $(ipmitool lan print ${lan_channel} | grep 'IP \
Address Source' | cut -f 2 -d : | grep -c DHCP) -eq 0",
    }
  }

  else {

    exec { "ipmi_set_static_${lan_channel}":
      command => "/usr/bin/ipmitool lan set ${lan_channel} ipsrc static",
      onlyif  => "/usr/bin/test $(ipmitool lan print ${lan_channel} | grep 'IP \
Address Source' | cut -f 2 -d : | grep -c DHCP) -eq 1",
      notify  => [Exec["ipmi_set_ipaddr_${lan_channel}"], Exec["ipmi_set_defgw_\
${lan_channel}"], Exec["ipmi_set_netmask_${lan_channel}"]],
    }

    exec { "ipmi_set_ipaddr_${lan_channel}":
      command => "/usr/bin/ipmitool lan set ${lan_channel} ipaddr ${ip}",
      onlyif  => "/usr/bin/test \"$(ipmitool lan print ${lan_channel} | grep \
'IP Address  ' | sed -e 's/.* : //g')\" != \"${ip}\"",
    }

    exec { "ipmi_set_defgw_${lan_channel}":
      command => "/usr/bin/ipmitool lan set ${lan_channel} defgw ipaddr ${gateway}",
      onlyif  => "/usr/bin/test \"$(ipmitool lan print ${lan_channel} | grep \
'Default Gateway IP' | sed -e 's/.* : //g')\" != \"${gateway}\"",
    }

    exec { "ipmi_set_netmask_${lan_channel}":
      command => "/usr/bin/ipmitool lan set ${lan_channel} netmask ${netmask}",
      onlyif  => "/usr/bin/test \"$(ipmitool lan print ${lan_channel} | grep \
'Subnet Mask' | sed -e 's/.* : //g')\" != \"${netmask}\"",
    }
  }
}
