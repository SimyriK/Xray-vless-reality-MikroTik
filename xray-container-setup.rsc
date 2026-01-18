# Xray Container Setup Script for RouterOS 7
# Usage: /system/script/run mikrotik-docker-check

# Global input function
:global inputFunc do={:return}

# ============================================================
# STEP 0: Check Container Mode
# ============================================================
:put "=== Step 0: Checking container mode ==="
:put ""

:local containerMode
:set containerMode [/system/device-mode/print as-value]
:if ([:typeof $containerMode] = "array") do={
    :set containerMode ($containerMode->"container")
} else={
    :set containerMode false
}

:if ($containerMode = "yes" || $containerMode = true || $containerMode = "true") do={
    :put "OK: Container mode is enabled"
} else={
    :put "WARNING: Container mode is NOT enabled!"
    :put ""
    :put "IMPORTANT: Enabling Container mode requires device reboot!"
    :put "You must reboot within 5 minutes after the update command."
    :put ""
    :put "Enable Container mode now? (y/n):"
    :local answer
    :set answer [$inputFunc]
    :if ($answer = "y" || $answer = "Y" || $answer = "yes") do={
        :put ""
        :put "Enabling Container mode..."
        /system/device-mode/update container=yes
    } else={
        :put ""
        :put "CANCELLED: Container mode not enabled."
        :error "Container mode is required. Script stopped."
    }
}

# ============================================================
# STEP 1: Check/Create RAM Disk for tmpfs
# ============================================================
:put ""
:put "=== Step 1: Checking RAM disk (tmpfs) ==="
:put ""

:local ramDiskExists
:set ramDiskExists false
:local ramDiskSlot
:set ramDiskSlot ""

:local disks
:set disks [/disk/print as-value where type="tmpfs"]
:if ([:len $disks] > 0) do={
    :set ramDiskExists true
    :set ramDiskSlot (($disks->0)->"slot")
    :put "OK: RAM disk exists: $ramDiskSlot"
} else={
    :put "RAM disk (tmpfs) not found."
    :put ""
    :put "RAM disk is recommended for container tmp directory."
    :put "Create RAM disk? (y/n):"
    :local createRam
    :set createRam [$inputFunc]
    
    :if ($createRam = "y" || $createRam = "Y" || $createRam = "yes") do={
        :put ""
        :put "Enter RAM disk size in MB [Enter = 100]:"
        :local ramSize
        :set ramSize [$inputFunc]
        :if ([:len $ramSize] = 0) do={
            :set ramSize "100"
        }
        
        :put "Enter slot name [Enter = ramstorage]:"
        :local slotName
        :set slotName [$inputFunc]
        :if ([:len $slotName] = 0) do={
            :set slotName "ramstorage"
        }
        
        # Check if slot name already exists
        :local slotExists
        :set slotExists [/disk/print as-value where slot=$slotName]
        :if ([:len $slotExists] > 0) do={
            :put "ERROR: Slot name '$slotName' already exists."
        } else={
            :local ramSizeMB
            :set ramSizeMB ($ramSize . "M")
            /disk/add slot=$slotName tmpfs-max-size=$ramSizeMB type=tmpfs
            :put "Created RAM disk: $slotName ($ramSizeMB)"
            :set ramDiskSlot $slotName
        }
    } else={
        :put "Skipped RAM disk creation."
    }
}

# ============================================================
# STEP 2: Check USB storage and select installation location
# ============================================================
:put ""
:put "=== Step 2: Checking storage location ==="
:put ""

:local installLocation
:set installLocation ""

# Get list of available disks (excluding tmpfs)
:local availableDisks
:set availableDisks [/disk/print as-value where type!="tmpfs"]

:local usbDisks
:set usbDisks [:toarray ""]
:local usbCount
:set usbCount 0

:foreach disk in=$availableDisks do={
    :local diskSlot
    :set diskSlot ($disk->"slot")
    :if ([:find $diskSlot "usb"] >= 0 || [:find $diskSlot "sd"] >= 0) do={
        :set usbDisks ($usbDisks, $diskSlot)
        :set usbCount ($usbCount + 1)
    }
}

:if ($usbCount > 0) do={
    :put "Found USB/SD storage:"
    :local idx
    :set idx 1
    :foreach usb in=$usbDisks do={
        :if ([:len $usb] > 0) do={
            :put "  $idx. $usb"
            :set idx ($idx + 1)
        }
    }
    :put "  $idx. Internal storage (router)"
    :put ""
    :put "Select installation location (1-$idx):"
    :local locationChoice
    :set locationChoice [$inputFunc]
    :local locationIdx
    :set locationIdx [:tonum $locationChoice]
    
    :if ($locationIdx >= 1 && $locationIdx < $idx) do={
        :local selIdx
        :set selIdx 1
        :foreach usb in=$usbDisks do={
            :if ($selIdx = $locationIdx) do={
                :set installLocation $usb
            }
            :set selIdx ($selIdx + 1)
        }
        :put "Selected: $installLocation"
    } else={
        :set installLocation ""
        :put "Selected: Internal storage"
    }
} else={
    :put "No USB/SD storage found. Using internal storage."
}

# ============================================================
# STEP 3: Check/Configure Container Registry
# ============================================================
:put ""
:put "=== Step 3: Checking container registry ==="
:put ""

:local containerConfig
:set containerConfig [/container/config/print as-value]

:local currentRegistry
:local currentTmpdir
:set currentRegistry ""
:set currentTmpdir ""

# Container config returns array with one element or direct object
:if ([:typeof $containerConfig] = "array") do={
    :if ([:len $containerConfig] > 0) do={
        :local configItem
        :set configItem ($containerConfig->0)
        :if ([:typeof $configItem] = "array") do={
            :set currentRegistry ($configItem->"registry-url")
            :set currentTmpdir ($configItem->"tmpdir")
        } else={
            :set currentRegistry ($containerConfig->"registry-url")
            :set currentTmpdir ($containerConfig->"tmpdir")
        }
    }
}

:local targetRegistry
:set targetRegistry "https://registry-1.docker.io"

:if ($currentRegistry = $targetRegistry) do={
    :put "OK: Registry configured: $currentRegistry"
} else={
    :put "Current registry: $currentRegistry"
    :put "Recommended registry: $targetRegistry"
    :put ""
    :put "Update registry to Docker Hub? (y/n):"
    :local updateReg
    :set updateReg [$inputFunc]
    
    :if ($updateReg = "y" || $updateReg = "Y" || $updateReg = "yes") do={
        :local tmpDir
        :if ([:len $ramDiskSlot] > 0) do={
            :set tmpDir ("/" . $ramDiskSlot)
        } else={
            :set tmpDir $currentTmpdir
        }
        /container/config/set registry-url=$targetRegistry tmpdir=$tmpDir
        :put "Registry updated to: $targetRegistry"
        :put "Tmpdir set to: $tmpDir"
    }
}

# ============================================================
# STEP 4: Create/Select VETH Interface
# ============================================================
:put ""
:put "=== Step 4: Checking VETH interface ==="
:put ""

:local selectedVeth
:set selectedVeth ""
:local vethAddress
:set vethAddress ""
:local vethGateway
:set vethGateway ""

:local existingVeths
:set existingVeths [/interface/veth/print as-value]

:if ([:len $existingVeths] > 0) do={
    :put "Found existing VETH interfaces:"
    :local vIdx
    :set vIdx 1
    :local vethNames
    :set vethNames [:toarray ""]
    
    :foreach veth in=$existingVeths do={
        :local vName
        :local vAddr
        :set vName ($veth->"name")
        :set vAddr ($veth->"address")
        :put "  $vIdx. $vName ($vAddr)"
        :set vethNames ($vethNames, $vName)
        :set vIdx ($vIdx + 1)
    }
    :put "  $vIdx. Create new VETH"
    :put ""
    :put "Select option (1-$vIdx):"
    :local vethChoice
    :set vethChoice [$inputFunc]
    :local vethIdx
    :set vethIdx [:tonum $vethChoice]
    
    :if ($vethIdx >= 1 && $vethIdx < $vIdx) do={
        # Use existing veth
        :local sIdx
        :set sIdx 1
        :foreach veth in=$existingVeths do={
            :if ($sIdx = $vethIdx) do={
                :set selectedVeth ($veth->"name")
                :set vethAddress ($veth->"address")
                :set vethGateway ($veth->"gateway")
            }
            :set sIdx ($sIdx + 1)
        }
        :put "Selected existing VETH: $selectedVeth"
    } else={
        # Create new veth - will be handled below
    }
}

:if ([:len $selectedVeth] = 0) do={
    :put ""
    :put "Creating new VETH interface..."
    :put ""
    :put "Enter VETH name [Enter = docker-xray-veth]:"
    :local newVethName
    :set newVethName [$inputFunc]
    :if ([:len $newVethName] = 0) do={
        :set newVethName "docker-xray-veth"
    }
    
    # Check if name exists
    :local nameExists
    :set nameExists [/interface/veth/print as-value where name=$newVethName]
    :if ([:len $nameExists] > 0) do={
        :put "ERROR: VETH name '$newVethName' already exists."
        :error "VETH name conflict. Script stopped."
    }
    
    :local newVethAddr
    :local containerIP
    :local gatewayIP
    :local ipValid
    :set ipValid false
    
    :while (!$ipValid) do={
        :put "Enter container IP/mask [Enter = 172.18.20.6/30]:"
        :set newVethAddr [$inputFunc]
        :if ([:len $newVethAddr] = 0) do={
            :set newVethAddr "172.18.20.6/30"
        }
        
        # Parse address
        :local addrOnly
        :local maskStr
        :local slashPos
        :set slashPos [:find $newVethAddr "/"]
        :if ([:typeof $slashPos] = "num" && $slashPos > 0) do={
            :set addrOnly [:pick $newVethAddr 0 $slashPos]
            :set maskStr [:pick $newVethAddr ($slashPos + 1) [:len $newVethAddr]]
        } else={
            :set addrOnly $newVethAddr
            :set maskStr "30"
        }
        :set containerIP $addrOnly
        
        # Find last dot position
        :local lastDotPos
        :set lastDotPos 0
        :local i
        :for i from=0 to=([:len $containerIP] - 1) do={
            :if ([:pick $containerIP $i ($i + 1)] = ".") do={
                :set lastDotPos $i
            }
        }
        
        # Extract prefix and last octet
        :local ipPrefix
        :local lastOctet
        :set ipPrefix [:pick $containerIP 0 ($lastDotPos + 1)]
        :set lastOctet [:pick $containerIP ($lastDotPos + 1) [:len $containerIP]]
        :local lastOctetNum
        :set lastOctetNum [:tonum $lastOctet]
        
        # Validate for /30
        :local remainder
        :set remainder ($lastOctetNum % 4)
        :local gatewayOctet
        
        :if ($maskStr = "30") do={
            :if ($remainder = 1) do={
                :set gatewayOctet ($lastOctetNum + 1)
                :set gatewayIP ($ipPrefix . [:tostr $gatewayOctet])
                :set ipValid true
            } else={
                :if ($remainder = 2) do={
                    :set gatewayOctet ($lastOctetNum - 1)
                    :set gatewayIP ($ipPrefix . [:tostr $gatewayOctet])
                    :set ipValid true
                } else={
                    :put ""
                    :put "ERROR: Invalid IP for /30 subnet!"
                    :put ""
                    :put "For /30, valid last octets are:"
                    :put "  1,2 | 5,6 | 9,10 | 13,14 | 17,18 | 21,22 | 25,26 | 29,30"
                    :put "  1,2 | 5,6 | 9,10 | 13,14 | 17,18 | 21,22 | 25,26 | 29,30 | 33,34 | 37,38"
                    :put "  41,42 | 45,46 | 49,50 | 53,54 | 57,58 | 61,62 | 65,66 | 69,70 | 73,74 | 77,78"
                    :put "  81,82 | 85,86 | 89,90 | 93,94 | 97,98 | 101,102 | 105,106 | 109,110 | 113,114"
                    :put "  117,118 | 121,122 | 125,126 | 129,130 | 133,134 | 137,138 | 141,142 | 145,146"
                    :put "  149,150 | 153,154 | 157,158 | 161,162 | 165,166 | 169,170 | 173,174 | 177,178"
                    :put "  181,182 | 185,186 | 189,190 | 193,194 | 197,198 | 201,202 | 205,206 | 209,210"
                    :put "  213,214 | 217,218 | 221,222 | 225,226 | 229,230 | 233,234 | 237,238 | 241,242"
                    :put "  245,246 | 249,250 | 253,254"
                    :put ""
                    :put "You entered: .$lastOctetNum which is:"
                    :if ($remainder = 0) do={
                        :put "  - Network address (not usable for hosts)"
                    }
                    :if ($remainder = 3) do={
                        :put "  - Broadcast address (not usable for hosts)"
                    }
                    :put ""
                    :put "Please enter a valid IP."
                    :put ""
                }
            }
        } else={
            # Not /30 - just use previous IP
            :set gatewayOctet ($lastOctetNum - 1)
            :set gatewayIP ($ipPrefix . [:tostr $gatewayOctet])
            :set ipValid true
        }
    }
    
    :put "Gateway (RouterOS IP) will be: $gatewayIP"
    
    /interface/veth/add address=$newVethAddr gateway=$gatewayIP gateway6="" name=$newVethName
    :put "Created VETH: $newVethName"
    
    :set selectedVeth $newVethName
    :set vethAddress $newVethAddr
    :set vethGateway $gatewayIP
}

# Save selected veth globally
:global selectedVethInterface
:set selectedVethInterface $selectedVeth

# ============================================================
# STEP 5: MSS Clamping Rule
# ============================================================
:put ""
:put "=== Step 5: Checking MSS clamping rule ==="
:put ""

:local mssRules
:set mssRules [/ip/firewall/mangle/print as-value where chain=forward action=change-mss out-interface=$selectedVeth]

:if ([:len $mssRules] > 0) do={
    :put "OK: MSS clamping rule exists for $selectedVeth"
} else={
    :put "MSS clamping rule not found for $selectedVeth"
    :put ""
    :put "Add MSS clamping rule? (y/n):"
    :local addMss
    :set addMss [$inputFunc]
    
    :if ($addMss = "y" || $addMss = "Y" || $addMss = "yes") do={
        /ip/firewall/mangle/add action=change-mss chain=forward new-mss=1360 out-interface=$selectedVeth passthrough=yes protocol=tcp tcp-flags=syn tcp-mss=1361-65535
        :put "Created MSS clamping rule"
    }
}

# ============================================================
# STEP 6: IP Address on VETH Interface
# ============================================================
:put ""
:put "=== Step 6: Checking IP address on VETH ==="
:put ""

:local vethIPs
:set vethIPs [/ip/address/print as-value where interface=$selectedVeth]

:if ([:len $vethIPs] > 0) do={
    :local existingIP
    :set existingIP (($vethIPs->0)->"address")
    :put "OK: IP address exists on $selectedVeth: $existingIP"
    :set vethGateway [:pick $existingIP 0 [:find $existingIP "/"]]
} else={
    :put "No IP address on $selectedVeth"
    :put ""
    
    # Calculate default IP from veth address
    :local defaultIP
    :if ([:len $vethGateway] > 0) do={
        :set defaultIP ($vethGateway . "/30")
    } else={
        :set defaultIP "172.18.20.5/30"
    }
    
    :put "Enter IP address for RouterOS side [Enter = $defaultIP]:"
    :local newIP
    :set newIP [$inputFunc]
    :if ([:len $newIP] = 0) do={
        :set newIP $defaultIP
    }
    
    /ip/address/add interface=$selectedVeth address=$newIP
    :put "Added IP: $newIP on $selectedVeth"
    :set vethGateway [:pick $newIP 0 [:find $newIP "/"]]
}

# ============================================================
# STEP 7: Check Routing Table and Route
# ============================================================
:put ""
:put "=== Step 7: Checking routing table ==="
:put ""

# First check RFC1918 address-list
:local rfc1918ListName
:set rfc1918ListName ""

:local entries10
:local entries172
:local entries192
:set entries10 [/ip/firewall/address-list/print as-value where address="10.0.0.0/8"]
:set entries172 [/ip/firewall/address-list/print as-value where address="172.16.0.0/12"]
:set entries192 [/ip/firewall/address-list/print as-value where address="192.168.0.0/16"]

:if ([:len $entries10] > 0 && [:len $entries172] > 0 && [:len $entries192] > 0) do={
    :local addr10List
    :local addr172List
    :local addr192List
    :set addr10List (($entries10->0)->"list")
    :set addr172List (($entries172->0)->"list")
    :set addr192List (($entries192->0)->"list")
    :if ($addr10List = $addr172List && $addr172List = $addr192List) do={
        :set rfc1918ListName $addr10List
        :put "OK: RFC1918 address-list found: $rfc1918ListName"
    }
}

:if ([:len $rfc1918ListName] = 0) do={
    :put "RFC1918 address-list not found. Creating..."
    :set rfc1918ListName "RFC1918"
    /ip/firewall/address-list/add address=10.0.0.0/8 list=$rfc1918ListName
    /ip/firewall/address-list/add address=172.16.0.0/12 list=$rfc1918ListName
    /ip/firewall/address-list/add address=192.168.0.0/16 list=$rfc1918ListName
    :put "Created RFC1918 address-list"
}

# Check routing tables with valid mangle rules
:local routingTables
:set routingTables [/routing/table/print as-value]
:local validTablesArray
:local validTablesCount
:set validTablesArray [:toarray ""]
:set validTablesCount 0

:foreach rt in=$routingTables do={
    :local tableName
    :set tableName ($rt->"name")
    :local markRoutingRules
    :set markRoutingRules [/ip/firewall/mangle/print as-value where chain=prerouting action=mark-routing new-routing-mark=$tableName]
    :if ([:len $markRoutingRules] > 0) do={
        :set validTablesArray ($validTablesArray, $tableName)
        :set validTablesCount ($validTablesCount + 1)
    }
}

:local selectedTable
:set selectedTable ""

:if ($validTablesCount > 0) do={
    :put "Found valid routing tables:"
    :local tIdx
    :set tIdx 1
    :foreach t in=$validTablesArray do={
        :if ([:len $t] > 0) do={
            :put "  $tIdx. $t"
            :set tIdx ($tIdx + 1)
        }
    }
    :put "  $tIdx. Create new routing table"
    :put ""
    :put "Select option (1-$tIdx):"
    :local tableChoice
    :set tableChoice [$inputFunc]
    :local tableIdx
    :set tableIdx [:tonum $tableChoice]
    
    :if ($tableIdx >= 1 && $tableIdx < $tIdx) do={
        :local sIdx
        :set sIdx 1
        :foreach t in=$validTablesArray do={
            :if ($sIdx = $tableIdx) do={
                :set selectedTable $t
            }
            :set sIdx ($sIdx + 1)
        }
        :put "Selected: $selectedTable"
    }
} else={
    :put "No valid routing tables found."
}

:if ([:len $selectedTable] = 0) do={
    :put ""
    :put "Creating new routing table..."
    :put "Enter table name [Enter = r_to_vpn]:"
    :local newTableName
    :set newTableName [$inputFunc]
    :if ([:len $newTableName] = 0) do={
        :set newTableName "r_to_vpn"
    }
    
    # Check if exists
    :local tableExists
    :set tableExists [/routing/table/print as-value where name=$newTableName]
    :if ([:len $tableExists] > 0) do={
        :put "Table '$newTableName' already exists, using it."
    } else={
        /routing/table/add disabled=no fib name=$newTableName
        :put "Created routing table: $newTableName"
    }
    :set selectedTable $newTableName
    
    # Create mangle rules
    :local connMark
    :local connMarkLocal
    :set connMark ("to-" . $newTableName)
    :set connMarkLocal ("to-" . $newTableName . "-local")
    
    # Check if address-list to_vpn exists
    :local toVpnList
    :set toVpnList [/ip/firewall/address-list/print as-value where list="to_vpn"]
    :if ([:len $toVpnList] = 0) do={
        :put "Creating address-list 'to_vpn' (add your target addresses here)"
        /ip/firewall/address-list/add address=8.8.8.8 list=to_vpn comment="Example - Google DNS"
    }
    
    # Create mangle rules
    /ip/firewall/mangle/add action=mark-connection chain=prerouting connection-mark=no-mark dst-address-list=to_vpn in-interface-list=!WAN new-connection-mark=$connMark passthrough=yes
    /ip/firewall/mangle/add action=mark-routing chain=prerouting connection-mark=$connMark in-interface-list=!WAN new-routing-mark=$newTableName passthrough=yes
    /ip/firewall/mangle/add action=mark-connection chain=output connection-mark=no-mark dst-address-list=to_vpn new-connection-mark=$connMarkLocal passthrough=yes
    /ip/firewall/mangle/add action=mark-routing chain=output connection-mark=$connMarkLocal new-routing-mark=$newTableName passthrough=yes
    :put "Created mangle rules for table: $newTableName"
}

# Save selected table globally
:global selectedRoutingTable
:set selectedRoutingTable $selectedTable

# Check/create route in the table
:local containerIP
:set containerIP ""
:local fullAddr
:set fullAddr ""
:local slashPos
:set slashPos 0

# Extract container IP from veth address (remove /mask)
:local vethInfo
:set vethInfo [/interface/veth/print as-value where name=$selectedVeth]
:if ([:len $vethInfo] > 0) do={
    :set fullAddr (($vethInfo->0)->"address")
}

# Remove /mask from address - convert to string first
:local addrStr
:set addrStr [:tostr $fullAddr]
:set slashPos [:find $addrStr "/"]
:if ([:typeof $slashPos] = "num" && $slashPos > 0) do={
    :set containerIP [:pick $addrStr 0 $slashPos]
} else={
    :set containerIP $addrStr
}

:put "Container IP for route gateway: $containerIP"

:local routeExists
:set routeExists [/ip/route/print as-value where routing-table=$selectedTable gateway=$containerIP]
:if ([:len $routeExists] > 0) do={
    :put "OK: Route via $containerIP exists in table $selectedTable"
} else={
    :put "Route via $containerIP not found in table $selectedTable"
    :put ""
    :put "Create default route (0.0.0.0/0) via $containerIP? (y/n):"
    :local createRoute
    :set createRoute [$inputFunc]
    
    :if ($createRoute = "y" || $createRoute = "Y" || $createRoute = "yes") do={
        /ip/route/add distance=1 dst-address=0.0.0.0/0 gateway=$containerIP routing-table=$selectedTable
        :put "Created route: 0.0.0.0/0 -> $containerIP in table $selectedTable"
    } else={
        :put "Route not created"
        :put "To create manually:"
        :put "  /ip/route/add distance=1 dst-address=0.0.0.0/0 gateway=$containerIP routing-table=$selectedTable"
    }
}

# ============================================================
# STEP 7.1: Check optional output chain rules
# ============================================================
:put ""
:put "=== Step 7.1: Checking output chain rules (optional) ==="
:put ""

:local outputMarkRoutingRules
:set outputMarkRoutingRules [/ip/firewall/mangle/print as-value where chain=output action=mark-routing new-routing-mark=$selectedTable]

:if ([:len $outputMarkRoutingRules] > 0) do={
    :put "OK: Output chain rules exist for table '$selectedTable'"
    :put "(Router's own traffic can be routed through VPN)"
} else={
    :put "Output chain rules NOT found for table '$selectedTable'"
    :put ""
    :put "These rules are OPTIONAL and needed only if you want to route"
    :put "traffic generated by the router itself (e.g., ping from router)."
    :put ""
    :put "Add output chain rules? (y/n):"
    :local addOutputRules
    :set addOutputRules [$inputFunc]
    
    :if ($addOutputRules = "y" || $addOutputRules = "Y" || $addOutputRules = "yes") do={
        # Generate connection-mark name
        :local outputConnMark
        :set outputConnMark ("to-" . $selectedTable . "-local")
        
        # Check if connection-mark already exists
        :local outputMarkExists
        :set outputMarkExists false
        :local existingOutputMarks
        :set existingOutputMarks [/ip/firewall/mangle/print as-value where action=mark-connection new-connection-mark=$outputConnMark]
        :if ([:len $existingOutputMarks] > 0) do={
            :set outputMarkExists true
        }
        
        :if ($outputMarkExists) do={
            :put "Connection-mark '$outputConnMark' already exists, skipping"
        } else={
            :put ""
            :put "Creating output chain rules..."
            
            # Create mark-connection rule for output chain
            /ip/firewall/mangle/add action=mark-connection chain=output connection-mark=no-mark dst-address-list=to_vpn new-connection-mark=$outputConnMark passthrough=yes
            :put "Created mark-connection rule (output): $outputConnMark"
            
            # Create mark-routing rule for output chain
            /ip/firewall/mangle/add action=mark-routing chain=output connection-mark=$outputConnMark new-routing-mark=$selectedTable passthrough=yes
            :put "Created mark-routing rule (output): $selectedTable"
            
            :put ""
            :put "SUCCESS: Output chain rules created."
        }
    } else={
        :put "Skipped output chain rules."
    }
}

# ============================================================
# STEP 8: Masquerade Rule
# ============================================================
:put ""
:put "=== Step 8: Checking masquerade rule ==="
:put ""

# Check for masquerade by interface or routing-mark
:local masqByInterface
:local masqByRoutingMark
:set masqByInterface [/ip/firewall/nat/print as-value where chain=srcnat action=masquerade out-interface=$selectedVeth]
:set masqByRoutingMark [/ip/firewall/nat/print as-value where chain=srcnat action=masquerade routing-mark=$selectedTable]

# Check if veth is in any interface-list that has masquerade
:local masqByList
:set masqByList false
:local vethLists
:set vethLists [/interface/list/member/print as-value where interface=$selectedVeth]
:foreach vl in=$vethLists do={
    :local listName
    :set listName ($vl->"list")
    :local masqListRules
    :set masqListRules [/ip/firewall/nat/print as-value where chain=srcnat action=masquerade out-interface-list=$listName]
    :if ([:len $masqListRules] > 0) do={
        :set masqByList true
    }
}

:if ([:len $masqByInterface] > 0 || [:len $masqByRoutingMark] > 0 || $masqByList) do={
    :put "OK: Masquerade rule exists"
} else={
    :put "Masquerade rule not found"
    :put ""
    :put "Add masquerade rule? Options:"
    :put "  1. By routing-mark ($selectedTable)"
    :put "  2. By out-interface ($selectedVeth)"
    :put "  3. Skip"
    :put ""
    :put "Select (1-3):"
    :local masqChoice
    :set masqChoice [$inputFunc]
    
    :if ($masqChoice = "1") do={
        /ip/firewall/nat/add chain=srcnat action=masquerade routing-mark=$selectedTable comment="MASQ for $selectedTable"
        :put "Created masquerade by routing-mark"
    }
    :if ($masqChoice = "2") do={
        /ip/firewall/nat/add chain=srcnat action=masquerade out-interface=$selectedVeth comment="MASQ for $selectedVeth"
        :put "Created masquerade by out-interface"
    }
}

# ============================================================
# STEP 9: Environment Variables
# ============================================================
:put ""
:put "=== Step 9: Container environment variables ==="
:put ""

:local selectedEnvList
:set selectedEnvList ""

:local existingEnvs
:set existingEnvs [/container/envs/print as-value]

# Get unique env list names
:local envListNames
:set envListNames [:toarray ""]
:local envListCount
:set envListCount 0

:foreach env in=$existingEnvs do={
    :local listName
    :set listName ($env->"list")
    :local found
    :set found false
    :foreach existing in=$envListNames do={
        :if ($existing = $listName) do={
            :set found true
        }
    }
    :if (!$found && [:len $listName] > 0) do={
        :set envListNames ($envListNames, $listName)
        :set envListCount ($envListCount + 1)
    }
}

:if ($envListCount > 0) do={
    :put "Found existing env lists:"
    :put ""
    :local eIdx
    :set eIdx 1
    :local envListVarsArray
    :set envListVarsArray [:toarray ""]
    
    :foreach el in=$envListNames do={
        :if ([:len $el] > 0) do={
            :put "  $eIdx. $el"
            # Show variables for this list
            :local listVars
            :set listVars [/container/envs/print as-value where list=$el]
            :foreach v in=$listVars do={
                :local vKey
                :local vVal
                :set vKey ($v->"key")
                :set vVal ($v->"value")
                :if ([:len $vVal] > 40) do={
                    :set vVal ([:pick $vVal 0 40] . "...")
                }
                :put "     $vKey = $vVal"
            }
            :put ""
            :set eIdx ($eIdx + 1)
        }
    }
    
    :local createNewIdx
    :local overwriteStartIdx
    :set createNewIdx $eIdx
    :set overwriteStartIdx ($eIdx + 1)
    
    :put "  $createNewIdx. Create new env list"
    
    # Add overwrite options for each existing list
    :local owIdx
    :set owIdx $overwriteStartIdx
    :foreach el in=$envListNames do={
        :if ([:len $el] > 0) do={
            :put "  $owIdx. Overwrite '$el' with new values"
            :set owIdx ($owIdx + 1)
        }
    }
    
    :local maxOption
    :set maxOption ($owIdx - 1)
    :put ""
    :put "Select (1-$maxOption):"
    :local envChoice
    :set envChoice [$inputFunc]
    :local envIdx
    :set envIdx [:tonum $envChoice]
    
    # Use existing list
    :if ($envIdx >= 1 && $envIdx < $createNewIdx) do={
        :local sIdx
        :set sIdx 1
        :foreach el in=$envListNames do={
            :if ($sIdx = $envIdx) do={
                :set selectedEnvList $el
            }
            :set sIdx ($sIdx + 1)
        }
        :put "Using existing env list: $selectedEnvList"
    }
    
    # Create new
    :if ($envIdx = $createNewIdx) do={
        :set selectedEnvList ""
    }
    
    # Overwrite existing
    :if ($envIdx >= $overwriteStartIdx && $envIdx <= $maxOption) do={
        :local owListIdx
        :set owListIdx ($envIdx - $overwriteStartIdx + 1)
        :local sIdx
        :set sIdx 1
        :foreach el in=$envListNames do={
            :if ($sIdx = $owListIdx) do={
                :set selectedEnvList $el
                # Remove existing variables
                :put "Removing existing variables from '$el'..."
                :local listVars
                :set listVars [/container/envs/print as-value where list=$el]
                :foreach v in=$listVars do={
                    :local vId
                    :set vId ($v->".id")
                    /container/envs/remove $vId
                }
                :put "Removed. Will create new variables."
                :set selectedEnvList ""
                # But use same list name for new vars
                :global overwriteEnvListName
                :set overwriteEnvListName $el
            }
            :set sIdx ($sIdx + 1)
        }
    }
}

:if ([:len $selectedEnvList] = 0) do={
    # Check if we're overwriting an existing list
    :global overwriteEnvListName
    :if ([:len $overwriteEnvListName] > 0) do={
        :set selectedEnvList $overwriteEnvListName
        :put ""
        :put "Creating new variables for: $selectedEnvList"
    } else={
        :put ""
        :put "Enter env list name [Enter = xvr]:"
        :local newEnvList
        :set newEnvList [$inputFunc]
        :if ([:len $newEnvList] = 0) do={
            :set newEnvList "xvr"
        }
        :set selectedEnvList $newEnvList
    }
    
    :put ""
    :put "Select configuration method:"
    :put "  1. FULL_STRING (complete connection string from 3x-ui)"
    :put "  2. SUBSCRIPTION_URL (subscription link)"
    :put "  3. Individual variables"
    :put ""
    :put "Select (1-3):"
    :local configMethod
    :set configMethod [$inputFunc]
    
    :if ($configMethod = "1") do={
        :put ""
        :put "Enter FULL_STRING (vless://...):"
        :local fullString
        :set fullString [$inputFunc]
        /container/envs/add key=FULL_STRING list=$selectedEnvList value=$fullString
        :put "Added FULL_STRING to $selectedEnvList"
    }
    
    :if ($configMethod = "2") do={
        :put ""
        :put "Enter SUBSCRIPTION_URL:"
        :local subUrl
        :set subUrl [$inputFunc]
        /container/envs/add key=SUBSCRIPTION_URL list=$selectedEnvList value=$subUrl
        
        :put "Enter SUBSCRIPTION_INDEX [Enter = 1]:"
        :local subIdx
        :set subIdx [$inputFunc]
        :if ([:len $subIdx] = 0) do={
            :set subIdx "1"
        }
        /container/envs/add key=SUBSCRIPTION_INDEX list=$selectedEnvList value=$subIdx
        
        :put "Enter update interval in hours [Enter = 24, 0 = disable]:"
        :local subInterval
        :set subInterval [$inputFunc]
        :if ([:len $subInterval] > 0 && $subInterval != "0") do={
            /container/envs/add key=SUBSCRIPTION_UPDATE_INTERVAL list=$selectedEnvList value=$subInterval
        }
        :put "Added subscription config to $selectedEnvList"
    }
    
    :if ($configMethod = "3") do={
        :put ""
        :put "Enter SERVER_ADDRESS:"
        :local sAddr
        :set sAddr [$inputFunc]
        /container/envs/add key=SERVER_ADDRESS list=$selectedEnvList value=$sAddr
        
        :put "Enter SERVER_PORT [Enter = 443]:"
        :local sPort
        :set sPort [$inputFunc]
        :if ([:len $sPort] = 0) do={ :set sPort "443" }
        /container/envs/add key=SERVER_PORT list=$selectedEnvList value=$sPort
        
        :put "Enter ID (UUID):"
        :local sId
        :set sId [$inputFunc]
        /container/envs/add key=ID list=$selectedEnvList value=$sId
        
        :put "Enter TYPE (tcp/xhttp) [Enter = tcp]:"
        :local sType
        :set sType [$inputFunc]
        :if ([:len $sType] = 0) do={ :set sType "tcp" }
        /container/envs/add key=TYPE list=$selectedEnvList value=$sType
        
        :put "Enter FP (fingerprint) [Enter = chrome]:"
        :local sFp
        :set sFp [$inputFunc]
        :if ([:len $sFp] = 0) do={ :set sFp "chrome" }
        /container/envs/add key=FP list=$selectedEnvList value=$sFp
        
        :put "Enter SNI:"
        :local sSni
        :set sSni [$inputFunc]
        /container/envs/add key=SNI list=$selectedEnvList value=$sSni
        
        :put "Enter PBK (public key):"
        :local sPbk
        :set sPbk [$inputFunc]
        /container/envs/add key=PBK list=$selectedEnvList value=$sPbk
        
        :put "Enter SID (short id):"
        :local sSid
        :set sSid [$inputFunc]
        /container/envs/add key=SID list=$selectedEnvList value=$sSid
        
        :put "Added individual variables to $selectedEnvList"
    }
}

:global selectedEnvListName
:set selectedEnvListName $selectedEnvList

# ============================================================
# STEP 10: Container Creation
# ============================================================
:put ""
:put "=== Step 10: Container setup ==="
:put ""

:local existingContainers
:set existingContainers [/container/print as-value where interface=$selectedVeth]

:if ([:len $existingContainers] > 0) do={
    :local cName
    :set cName (($existingContainers->0)->"hostname")
    :put "Container already exists with interface $selectedVeth"
    :put "Hostname: $cName"
    :put ""
    :put "Recreate container? (y/n):"
    :local recreate
    :set recreate [$inputFunc]
    
    :if ($recreate = "y" || $recreate = "Y" || $recreate = "yes") do={
        :local cName
        :local cStatus
        :local cRunning
        :set cName (($existingContainers->0)->"name")
        :set cStatus (($existingContainers->0)->"status")
        :set cRunning (($existingContainers->0)->"running")
        
        :put ""
        :put "  Container: $cName"
        :local runningState
        :if ($cRunning = true || $cRunning = "true") do={
            :set runningState "RUNNING"
        } else={
            :set runningState "STOPPED"
        }
        :put "  State: $runningState"
        :put ""
        
        # Check if running
        :local needStop
        :set needStop false
        :if ($cRunning = true || $cRunning = "true") do={
            :set needStop true
        }
        
        # Stop if running
        :if ($needStop) do={
            :put "  [1/3] Stopping container..."
            :do {
                /container/stop [find name=$cName]
            } on-error={}
            
            # Wait for container to stop (up to 30 seconds)
            :local waitCount
            :set waitCount 0
            :local stillRunning
            :set stillRunning true
            :while ($stillRunning && $waitCount < 30) do={
                :local checkContainer
                :set checkContainer [/container/print as-value where name=$cName]
                :if ([:len $checkContainer] > 0) do={
                    :local curRunning
                    :set curRunning (($checkContainer->0)->"running")
                    :if ($curRunning = false || $curRunning = "false") do={
                        :set stillRunning false
                    } else={
                        :if (($waitCount % 5) = 0 && $waitCount > 0) do={
                            :put "        Waiting... ($waitCount sec)"
                        }
                    }
                } else={
                    :set stillRunning false
                }
                :if ($stillRunning) do={
                    :delay 1s
                    :set waitCount ($waitCount + 1)
                }
            }
            
            :if ($stillRunning) do={
                :put "  ERROR: Container did not stop after 30 seconds."
                :put "  Please stop manually and run script again:"
                :put "    /container/stop [find name=$cName]"
                :error "Container stop timeout. Script stopped."
            }
            :put "        OK - Stopped"
        } else={
            :put "  [1/3] Container already stopped - OK"
        }
        
        # Wait before remove
        :put "  [2/3] Waiting 5 seconds..."
        :delay 5s
        :put "        OK"
        
        :put "  [3/3] Removing container (up to 10 attempts)..."
        :local removeSuccess
        :set removeSuccess false
        :local removeAttempt
        :set removeAttempt 0
        
        :while (!$removeSuccess && $removeAttempt < 10) do={
            :set removeAttempt ($removeAttempt + 1)
            :do {
                /container/remove [find name=$cName]
                :set removeSuccess true
            } on-error={
                :if ($removeAttempt < 10) do={
                    :put "        Attempt $removeAttempt/10 failed, waiting 5 sec..."
                    :delay 5s
                }
            }
        }
        
        :if (!$removeSuccess) do={
            :put "  ERROR: Cannot remove container after 10 attempts."
            :put "  Please remove manually and run script again:"
            :put "    /container/remove [find name=$cName]"
            :error "Container removal failed. Script stopped."
        }
        :put "        OK - Removed"
        :put ""
        
        # Verify container is gone
        :delay 2s
        :local verifyRemoved
        :set verifyRemoved [/container/print as-value where interface=$selectedVeth]
        :if ([:len $verifyRemoved] > 0) do={
            :put "ERROR: Container still exists after removal."
            :put "Please remove manually and run script again."
            :error "Container still exists. Script stopped."
        }
    } else={
        :put "Keeping existing container"
    }
}

:local containerExists
:set containerExists [/container/print as-value where interface=$selectedVeth]
:if ([:len $containerExists] = 0) do={
    :put ""
    :put "Enter container hostname [Enter = xray-vless]:"
    :local cHostname
    :set cHostname [$inputFunc]
    :if ([:len $cHostname] = 0) do={
        :set cHostname "xray-vless"
    }
    
    :local rootDir
    :if ([:len $installLocation] > 0) do={
        :set rootDir ($installLocation . "/docker/" . $cHostname)
    } else={
        :set rootDir $cHostname
    }
    
    :put "Root directory: $rootDir"
    :put ""
    :put "Creating container from Docker Hub..."
    
    /container/add hostname=$cHostname interface=$selectedVeth envlist=$selectedEnvList root-dir=$rootDir logging=yes start-on-boot=yes remote-image=simyrik/xray-mikrotik:latest
    
    :put "Container created. It will start downloading the image."
    :put "Check status with: /container/print"
}

# ============================================================
# STEP 11: Firewall Rules for DNS
# ============================================================
:put ""
:put "=== Step 11: Checking firewall rules for DNS ==="
:put ""

# Use global veth interface
:global selectedVethInterface
:local selectedVeth
:set selectedVeth $selectedVethInterface

# Get container IP and RouterOS IP
:local vethInfo
:set vethInfo [/interface/veth/print as-value where name=$selectedVeth]
:local containerIP
:local routerIP
:if ([:len $vethInfo] > 0) do={
    :local fullAddr
    :local addrStr
    :local slashPos
    :set fullAddr (($vethInfo->0)->"address")
    :set addrStr [:tostr $fullAddr]
    :set slashPos [:find $addrStr "/"]
    :if ([:typeof $slashPos] = "num" && $slashPos > 0) do={
        :set containerIP [:pick $addrStr 0 $slashPos]
    } else={
        :set containerIP $addrStr
    }
}
:local ipInfo
:set ipInfo [/ip/address/print as-value where interface=$selectedVeth]
:if ([:len $ipInfo] > 0) do={
    :local fullAddr
    :local addrStr
    :local slashPos
    :set fullAddr (($ipInfo->0)->"address")
    :set addrStr [:tostr $fullAddr]
    :set slashPos [:find $addrStr "/"]
    :if ([:typeof $slashPos] = "num" && $slashPos > 0) do={
        :set routerIP [:pick $addrStr 0 $slashPos]
    } else={
        :set routerIP $addrStr
    }
}

# Check for DNS rules - search by interface and port only
:local dnsRules
:set dnsRules [/ip/firewall/filter/print as-value where chain=input in-interface="$selectedVeth" dst-port="53"]

# Need at least 2 rules (UDP and TCP)
:if ([:len $dnsRules] >= 2) do={
    :put "OK: DNS firewall rules exist (found $[:len $dnsRules] rules)"
} else={
    :put "DNS firewall rules not found or incomplete"
    :put ""
    :put "Add DNS rules for container? (y/n):"
    :local addDns
    :set addDns [$inputFunc]
    
    :if ($addDns = "y" || $addDns = "Y" || $addDns = "yes") do={
        /ip/firewall/filter/add chain=input in-interface=$selectedVeth src-address=$containerIP dst-address=$routerIP protocol=udp dst-port=53 action=accept comment="container -> local DNS (UDP/53)"
        :put "Created DNS UDP rule"
        /ip/firewall/filter/add chain=input in-interface=$selectedVeth src-address=$containerIP dst-address=$routerIP protocol=tcp dst-port=53 action=accept comment="container -> local DNS (TCP/53)"
        :put "Created DNS TCP rule"
        :put "NOTE: Move these rules above any drop rules in firewall filter"
    }
}

# ============================================================
# STEP 12: Start Container
# ============================================================
:put ""
:put "=== Step 12: Start container ==="
:put ""

# Use global veth interface
:global selectedVethInterface
:local selectedVeth
:set selectedVeth $selectedVethInterface

# Wait for container to be ready (downloading/extracting)
# Flags: R - running, S - stopped, E - extracting
:put "Waiting for container to be ready..."
:local waitAttempts
:set waitAttempts 0
:local containerReady
:set containerReady false

:while (!$containerReady && $waitAttempts < 120) do={
    :local containerCheck
    :set containerCheck [/container/print as-value where interface=$selectedVeth]
    
    :if ([:len $containerCheck] > 0) do={
        :local checkStatus
        :local checkRunning
        :local checkExtracting
        :set checkStatus (($containerCheck->0)->"status")
        :set checkRunning (($containerCheck->0)->"running")
        :set checkExtracting (($containerCheck->0)->"extracting")
        
        # Container is ready if: stopped (not running, not extracting) or running
        :if ($checkRunning = true || $checkRunning = "true") do={
            :set containerReady true
            :put "Container is running"
        } else={
            :if ($checkExtracting = true || $checkExtracting = "true" || $checkStatus = "extracting" || $checkStatus = "downloading") do={
                # Still extracting/downloading
                :if (($waitAttempts % 5) = 0) do={
                    :put "Extracting/downloading... (waiting $waitAttempts sec)"
                }
                :delay 1s
                :set waitAttempts ($waitAttempts + 1)
            } else={
                # Not running, not extracting = stopped/ready
                :set containerReady true
                :put "Container ready (stopped)"
            }
        }
    } else={
        # No container found yet
        :put "Waiting for container..."
        :delay 2s
        :set waitAttempts ($waitAttempts + 2)
    }
}

:if (!$containerReady) do={
    :put "Container is still downloading/extracting after 2 minutes."
    :put "Check status manually: /container/print"
    :put ""
}

# Find container by interface
:local containerToStart
:set containerToStart [/container/print as-value where interface=$selectedVeth]

:if ([:len $containerToStart] > 0) do={
    :local cName
    :local cContainerName
    :local cRunning
    :local cExtracting
    :set cName (($containerToStart->0)->"hostname")
    :set cContainerName (($containerToStart->0)->"name")
    :set cRunning (($containerToStart->0)->"running")
    :set cExtracting (($containerToStart->0)->"extracting")
    
    :if ($cRunning = true || $cRunning = "true") do={
        # Already reported above
    } else={
        :if ($cExtracting = true || $cExtracting = "true") do={
            :put "Container is still extracting"
            :put "Wait for extraction to complete and run script again"
            :put "Check status with: /container/print"
        } else={
            # Container is stopped - ready to start
            :put ""
            :put "Start container now? (y/n):"
            :local startContainer
            :set startContainer [$inputFunc]
            
            :if ($startContainer = "y" || $startContainer = "Y" || $startContainer = "yes") do={
                :put ""
                :put "Starting container..."
                /container/start [find name=$cContainerName]
                :delay 3s
                :local newStatus
                :local newRunning
                :set newStatus [/container/print as-value where interface=$selectedVeth]
                :if ([:len $newStatus] > 0) do={
                    :set newRunning (($newStatus->0)->"running")
                    :if ($newRunning = true || $newRunning = "true") do={
                        :put "Container is now RUNNING"
                    } else={
                        :put "Container status: check with /container/print"
                    }
                }
            } else={
                :put "Container not started"
                :local startCmd
                :set startCmd "/container/start [find name=$cContainerName]"
                :put "To start manually: $startCmd"
            }
        }
    }
} else={
    :put "No container found for interface $selectedVeth"
}

# ============================================================
# FINISH
# ============================================================
:put ""
:put "=========================================="
:put "Setup complete!"
:put "=========================================="
:put ""
:put "Summary:"
:put "  VETH interface: $selectedVeth"
:put "  Routing table: $selectedTable"
:put "  Env list: $selectedEnvList"
:put ""
:put "Useful commands:"
:put "  Check container: /container/print"
:put "  Container logs: /container/shell 0"
:put "  Add VPN targets: /ip/firewall/address-list/add list=to_vpn address=X.X.X.X"
:put ""
