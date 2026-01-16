<#
    .SYNOPSIS
    Node-Bluetooth Windows Driver (PowerShell / WinRT)
    
    .DESCRIPTION
    Replaces the compiled C# driver. Uses Windows.Devices.Bluetooth* namespaces via WinRT.
    Communicates via JSON over Stdin/Stdout.
#>

# -----------------------------------------------------------------------------
# 1. Load WinRT Types
# -----------------------------------------------------------------------------
# We need to load the Windows Runtime types for Bluetooth.
# On Windows 10/11, these are available. 
# Sometimes requires explicit loading if not already present in the PS session.

try {
    [void][Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]
    [void][Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth.Advertisement, ContentType=WindowsRuntime]
    [void][Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristic, Windows.Devices.Bluetooth.GenericAttributeProfile, ContentType=WindowsRuntime]
    [void][Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType=WindowsRuntime]
} catch {
    # Fallback for some environments: explicitly load assembly
    # This might fail on non-Windows 10+ or if types are missing
    Write-Error "Could not load WinRT Bluetooth types. Ensure you are on Windows 10+."
    exit 1
}

# -----------------------------------------------------------------------------
# 2. State & Globals
# -----------------------------------------------------------------------------
$watcher = $null
$connectedDevices = @{}          # Map: UUID (String) -> BluetoothLEDevice
$serviceCache = @{}              # Map: UUID -> List[GattDeviceService] or similar
$characteristicCache = @{}       # Map: "UUID/ServiceUUID/CharUUID" -> GattCharacteristic
$subscribedChars = @{}           # Map: "Key" -> GattCharacteristic (for cleanup)

# JSON Helper
function Send-Event {
    param($name, $data)
    $evt = @{
        event = $name
        data = $data
    }
    # -Depth 10 to ensure nested objects serialize correctly
    [Console]::WriteLine(($evt | ConvertTo-Json -Compress -Depth 10))
}

function Log {
    param($msg)
    [Console]::Error.WriteLine($msg)
}

# -----------------------------------------------------------------------------
# 3. Bluetooth Logic
# -----------------------------------------------------------------------------

function Start-Scan {
    if ($watcher -eq $null) {
        $script:watcher = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
        $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
        
        # Register Event
        Register-ObjectEvent -InputObject $watcher -EventName "Received" -Action {
             param($sender, $args)
             
             # Extract Data
             $addr = $args.BluetoothAddress.ToString("X")
             $name = $args.Advertisement.LocalName
             $rssi = $args.RawSignalStrengthInDBm
             
             $serviceUuids = @()
             foreach ($u in $args.Advertisement.ServiceUuids) {
                $serviceUuids += $u.ToString()
             }

             $data = @{
                uuid = $addr
                rssi = $rssi
                name = $name
                serviceUuids = $serviceUuids
             }
             
             # We must call Send-Event available in script scope
             # Note: simple invocation inside event handler might need care with scope, 
             # but usually ConvertTo-Json works fine if output goes to stdout.
             $evt = @{ event = "device"; data = $data }
             [Console]::WriteLine(($evt | ConvertTo-Json -Compress -Depth 10))
        } | Out-Null
        
        Register-ObjectEvent -InputObject $watcher -EventName "Stopped" -Action {
            [Console]::WriteLine(('{"event":"scanStop","data":null}'))
        } | Out-Null
    }
    
    $watcher.Start()
    Send-Event "scanStart" $null
}

function Stop-Scan {
    if ($watcher -ne $null) {
        $watcher.Stop()
    }
}

function Connect-Device ($uuid) {
    try {
        $addr = [Convert]::ToUInt64($uuid, 16)
        # Async call - we'll wait synchronously for simplicity in this script runner 
        # or use internal async wrapper. 
        # PowerShell handling of WinRT AsyncWaitHandle is specific.
        $op = [Windows.Devices.Bluetooth.BluetoothLEDevice]::FromBluetoothAddressAsync($addr)
        
        # Wait for result
        while ($op.Status -eq "Started") { Start-Sleep -Milliseconds 50 }
        $device = $op.GetResults()

        if ($device -eq $null) {
            Log "Device not found: $uuid"
            return
        }

        $connectedDevices[$uuid] = $device
        
        # Monitor connection status (optional, but good for "disconnected" event)
        # Note: Managing object events for many devices in PS can leak if not careful.
        # For now, we simulate "connected" immediately.
        
        Send-Event "connected" @{ uuid = $uuid }
        
    } catch {
        Log "Connect failed: $_"
    }
}

function Disconnect-Device ($uuid) {
    if ($connectedDevices.ContainsKey($uuid)) {
        $params = $connectedDevices[$uuid]
        # In WinRT, 'Dispose' or 'Close' disconnects
        $params.Dispose()
        $connectedDevices.Remove($uuid)
        Send-Event "disconnected" @{ uuid = $uuid }
    }
}

function Discover-Services ($uuid, $filter) {
    if (-not $connectedDevices.ContainsKey($uuid)) { return }
    $device = $connectedDevices[$uuid]
    
    # GetGattServicesAsync
    $op = $device.GetGattServicesAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)
    while ($op.Status -eq "Started") { Start-Sleep -Milliseconds 50 }
    $result = $op.GetResults()
    
    if ($result.Status -eq "Success") {
        $sList = @()
        foreach ($s in $result.Services) {
            $sList += $s.Uuid.ToString()
            # Cache service object if needed? 
            # WinRT usually allows re-fetching quickly, but let's keep it simple.
        }
        Send-Event "services" @{ uuid = $uuid; services = $sList }
    } else {
        Log "DiscoverServices failed: $($result.Status)"
    }
}

function Discover-Characteristics ($uuid, $serviceId, $filter) {
    if (-not $connectedDevices.ContainsKey($uuid)) { return }
    $device = $connectedDevices[$uuid]
    
    # 1. Get Service
    # We need to match GUID
    try { $sGuid = [Guid]::Parse($serviceId) } catch { Log "Invalid GUID $serviceId"; return }
    
    $opS = $device.GetGattServicesForUuidAsync($sGuid)
    while ($opS.Status -eq "Started") { Start-Sleep -Milliseconds 50 }
    $resS = $opS.GetResults()
    
    if ($resS.Services.Count -eq 0) { Log "Service not found"; return }
    $serviceObj = $resS.Services[0]
    
    # 2. Get Characteristics
    $opC = $serviceObj.GetCharacteristicsAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)
    while ($opC.Status -eq "Started") { Start-Sleep -Milliseconds 50 }
    $resC = $opC.GetResults()
    
    if ($resC.Status -eq "Success") {
        $cList = @()
        foreach ($c in $resC.Characteristics) {
            $cList += $c.Uuid.ToString()
        }
        Send-Event "characteristics" @{ uuid = $uuid; service = $serviceId; characteristics = $cList }
    }
}

function Find-Characteristic ($uuid, $serviceId, $charId) {
    if (-not $connectedDevices.ContainsKey($uuid)) { return $null }
    $device = $connectedDevices[$uuid]
    
    # Simple lookup - in production, cache these objects to avoid roundtrips
    try {
        $sGuid = [Guid]::Parse($serviceId)
        $cGuid = [Guid]::Parse($charId)
    } catch { return $null }

    $opS = $device.GetGattServicesForUuidAsync($sGuid)
    while ($opS.Status -eq "Started") { Start-Sleep -Milliseconds 10 }
    $resS = $opS.GetResults()
    if ($resS.Services.Count -eq 0) { return $null }
    
    $opC = $resS.Services[0].GetCharacteristicsForUuidAsync($cGuid)
    while ($opC.Status -eq "Started") { Start-Sleep -Milliseconds 10 }
    $resC = $opC.GetResults()
    
    if ($resC.Characteristics.Count -gt 0) {
        return $resC.Characteristics[0]
    }
    return $null
}

function Read-Value ($uuid, $serviceId, $charId) {
    $charObj = Find-Characteristic $uuid $serviceId $charId
    if ($charObj -eq $null) { Log "Char not found for read"; return }
    
    $op = $charObj.ReadValueAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)
    while ($op.Status -eq "Started") { Start-Sleep -Milliseconds 20 }
    $res = $op.GetResults()
    
    if ($res.Status -eq "Success") {
        # Read Buffer
        $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($res.Value)
        $bytes = New-Object byte[] $res.Value.Length
        $reader.ReadBytes($bytes)
        
        # Bytes to Hex
        $hex = ($bytes | ForEach-Object { "{0:X2}" -f $_ }) -join ""
        
        Send-Event "read" @{ uuid = $uuid; service = $serviceId; characteristic = $charId; data = $hex }
    } else {
        Log "Read failed: $($res.Status)"
    }
}

function Write-Value ($uuid, $serviceId, $charId, $hexData) {
    $charObj = Find-Characteristic $uuid $serviceId $charId
    if ($charObj -eq $null) { Log "Char not found for write"; return }
    
    # Parse Hex
    $bytes = @()
    if ($hexData.Length % 2 -ne 0) { $hexData = "0" + $hexData }
    for ($i = 0; $i -lt $hexData.Length; $i+=2) {
        $bytes += [Convert]::ToByte($hexData.Substring($i, 2), 16)
    }
    
    $writer = New-Object Windows.Storage.Streams.DataWriter
    $writer.WriteBytes($bytes)
    
    # Determine Write Type
    $props = $charObj.CharacteristicProperties
    $wType = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption]::WriteWithoutResponse
    if ($props -band [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Write) {
        $wType = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattWriteOption]::WriteWithResponse
    }
    
    $op = $charObj.WriteValueWithResultAsync($writer.DetachBuffer(), $wType)
    while ($op.Status -eq "Started") { Start-Sleep -Milliseconds 20 }
    $res = $op.GetResults()
    
    $success = ($res.Status -eq "Success")
    Send-Event "write" @{ uuid = $uuid; service = $serviceId; characteristic = $charId; success = $success }
}

function Receive-Notification {
    param($sender, $args)
    # Args is GattValueChangedEventArgs
    $reader = [Windows.Storage.Streams.DataReader]::FromBuffer($args.CharacteristicValue)
    $bytes = New-Object byte[] $args.CharacteristicValue.Length
    $reader.ReadBytes($bytes)
    $hex = ($bytes | ForEach-Object { "{0:X2}" -f $_ }) -join ""
    
    # We need context (UUIDs). $sender is the Characteristic.
    # Warning: Accessing sender properties might be slow or blocking, but usually ok.
    # Service->Device might be disposed if we are not careful? 
    # Actually we just keep the device connected.
    
    try {
        $cUuid = $sender.Uuid.ToString()
        $sUuid = $sender.Service.Uuid.ToString()
        # Device address...
        $dAddr = $sender.Service.Device.BluetoothAddress.ToString("X")
        
        # Output directly
        $evt = @{
            event = "read"
            data = @{
                uuid = $dAddr
                service = $sUuid
                characteristic = $cUuid
                data = $hex
            }
        }
        [Console]::WriteLine(($evt | ConvertTo-Json -Compress -Depth 10))
    } catch {
        Log "Error in notification: $_"
    }
}

function Subscribe-Value ($uuid, $serviceId, $charId, $enable) {
    $charObj = Find-Characteristic $uuid $serviceId $charId
    if ($charObj -eq $null) { Log "Char not found for subscribe"; return }
    
    $desc = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattClientCharacteristicConfigurationDescriptorValue]::None
    
    if ($enable) {
        $props = $charObj.CharacteristicProperties
        # Default notify
        $desc = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattClientCharacteristicConfigurationDescriptorValue]::Notify
        if ($props -band [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Indicate) {
            $desc = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattClientCharacteristicConfigurationDescriptorValue]::Indicate
        }
    }
    
    $op = $charObj.WriteClientCharacteristicConfigurationDescriptorAsync($desc)
    while ($op.Status -eq "Started") { Start-Sleep -Milliseconds 20 }
    $status = $op.GetResults()
    
    if ($status -eq "Success") {
        # Hook event
        # PowerShell eventing with WinRT delegates can be tricky ("Register-ObjectEvent")
        # Unique Source Identifier needed? 
        
        # We need to map this characteristic to a persistent event handler
        # For simplicity in this script, we'll assign a script block. 
        # Note: Removing events in PS is hard if we don't track the job/event subscriber.
        
        # Cleaning up previous subscriptions for this specific char is tricky without a unique key map.
        # But let's assume one sub per char.
        
        if ($enable) {
             # Add Event
             # We use the native .NET event add if possible or Register-ObjectEvent
             # Register-ObjectEvent is safer for script lifecycle.
             
             # Note: We need a unique SourceIdentifier for each char to unregister later?
             # Or just let them pile up? (Bad).
             # Let's use SourceIdentifier = "Notify-$charId"
             
             Unsubscribe-Value $uuid $serviceId $charId # clear old
             
             Register-ObjectEvent -InputObject $charObj -EventName "ValueChanged" -SourceIdentifier "Notify-$charId" -Action {
                Receive-Notification $sender $args
             } | Out-Null
        } else {
             Unsubscribe-Value $uuid $serviceId $charId
        }
        
    } else {
        Log "Subscribe failed: $status"
    }
}

function Unsubscribe-Value ($uuid, $serviceId, $charId) {
    $id = "Notify-$charId"
    Get-Job -Name $id -ErrorAction SilentlyContinue | Remove-Job -Force
    Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# 4. Main Loop
# -----------------------------------------------------------------------------
Send-Event "stateChange" "poweredOn"

while ($true) {
    $line = [Console]::ReadLine()
    if ($line -eq $null) { break } # EOF
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    
    try {
        $cmd = $line | ConvertFrom-Json
        
        switch ($cmd.command) {
            "scan" { Start-Scan }
            "stopScan" { Stop-Scan }
            "connect" { Connect-Device $cmd.uuid }
            "disconnect" { Disconnect-Device $cmd.uuid }
            "discoverServices" { Discover-Services $cmd.uuid $cmd.services }
            "discoverCharacteristics" { Discover-Characteristics $cmd.uuid $cmd.service $cmd.characteristics }
            "read" { Read-Value $cmd.uuid $cmd.service $cmd.characteristic }
            "write" { Write-Value $cmd.uuid $cmd.service $cmd.characteristic $cmd.data }
            "subscribe" { Subscribe-Value $cmd.uuid $cmd.service $cmd.characteristic $cmd.notify }
            default { Log "Unknown command: $($cmd.command)" }
        }
    } catch {
        Log "Error processing line: $_"
    }
}
