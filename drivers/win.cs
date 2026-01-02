using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

// Compile with: 
// csc /target:exe /out:drivers/win.exe /r:"C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.19041.0\Windows.winmd" /r:"C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETCore\v4.5\System.Runtime.WindowsRuntime.dll" drivers/win.cs
// Note: Paths to Windows.winmd may vary.

namespace NodeBluetooth
{
    [DataContract]
    public class Command
    {
        [DataMember] public string command;
        [DataMember] public string uuid;
        [DataMember] public List<string> services;
        [DataMember] public string service;
        [DataMember] public List<string> characteristics;
        [DataMember] public string characteristic;
        [DataMember] public string data; // Hex
    }

    [DataContract]
    public class Response
    {
        [DataMember] public string eventName;
        [DataMember(Name = "event")] public string Event { get { return eventName; } set { eventName = value; } }
        [DataMember] public object data;
    }

    class Program
    {
        static BluetoothLEAdvertisementWatcher watcher;
        static Dictionary<string, BluetoothLEDevice> connectedDevices = new Dictionary<string, BluetoothLEDevice>();
        static Dictionary<string, Dictionary<string, Guid>> serviceCache = new Dictionary<string, Dictionary<string, Guid>>(); // DeviceID -> { ServiceUUID-String -> ServiceGUID }
        
        static void Main(string[] args)
        {
            // Set up watcher
            watcher = new BluetoothLEAdvertisementWatcher();
            watcher.ScanningMode = BluetoothLEScanningMode.Active;
            watcher.Received += OnAdvertisementReceived;
            watcher.Stopped += (s, e) => SendEvent("scanStop", null);

            // Report ready
            SendEvent("stateChange", "poweredOn"); // TODO: Check actual radio state

            // Input loop
            var serializer = new DataContractJsonSerializer(typeof(Command));
            var inputStream = Console.OpenStandardInput();
            
            // Allow long lines? buffer?
            // Simple line-based reading
            while (true)
            {
                try
                {
                    string line = Console.ReadLine();
                    if (line == null) break; // EOF
                    if (string.IsNullOrWhiteSpace(line)) continue;

                    using (var ms = new MemoryStream(Encoding.UTF8.GetBytes(line)))
                    {
                        var cmd = (Command)serializer.ReadObject(ms);
                        HandleCommand(cmd);
                    }
                }
                catch (Exception ex)
                {
                    Log("Error parsing command: " + ex.Message);
                }
            }
        }

        static async void HandleCommand(Command cmd)
        {
            try 
            {
                switch (cmd.command)
                {
                    case "scan":
                        watcher.Start();
                        SendEvent("scanStart", null);
                        break;
                    case "stopScan":
                        watcher.Stop();
                        break;
                    case "connect":
                        if (!string.IsNullOrEmpty(cmd.uuid)) await Connect(cmd.uuid);
                        break;
                    case "disconnect":
                        if (!string.IsNullOrEmpty(cmd.uuid)) Disconnect(cmd.uuid);
                        break;
                    case "discoverServices":
                        if (!string.IsNullOrEmpty(cmd.uuid)) await DiscoverServices(cmd.uuid, cmd.services);
                        break;
                    case "discoverCharacteristics":
                        if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service))
                            await DiscoverCharacteristics(cmd.uuid, cmd.service, cmd.characteristics);
                        break;
                    case "read":
                        if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service) && !string.IsNullOrEmpty(cmd.characteristic))
                            await ReadValue(cmd.uuid, cmd.service, cmd.characteristic);
                        break;
                    case "write":
                         if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service) && !string.IsNullOrEmpty(cmd.characteristic))
                            await WriteValue(cmd.uuid, cmd.service, cmd.characteristic, cmd.data);
                        break;
                    default:
                        Log("Unknown command: " + cmd.command);
                        break;
                }
            } 
            catch (Exception ex) 
            {
                Log("Error handling command " + cmd.command + ": " + ex.Message);
            }
        }

        static void OnAdvertisementReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
        {
            var deviceId = args.BluetoothAddress.ToString("X");
            var name = args.Advertisement.LocalName;
            
            var data = new Dictionary<string, object>
            {
                { "uuid", deviceId },
                { "rssi", args.RawSignalStrengthInDBm },
                { "name", name }
            };

            var services = new List<string>();
            foreach(var uuid in args.Advertisement.ServiceUuids) {
                services.Add(uuid.ToString());
            }
            data["serviceUuids"] = services;

            SendEvent("device", data);
        }

        static async Task Connect(string uuid)
        {
            try 
            {
                ulong addr = Convert.ToUInt64(uuid, 16);
                var device = await BluetoothLEDevice.FromBluetoothAddressAsync(addr);
                
                if (device == null)
                {
                    Log("Could not find device: " + uuid);
                    return;
                }

                connectedDevices[uuid] = device;
                device.ConnectionStatusChanged += Device_ConnectionStatusChanged;
                
                // Note: Windows doesn't fully "connect" until you do something with GATT.
                // But we can signal we possess the object.
                // To force connection, we often request services or similar.
                // For now, let's pretend connected and rely on auto-connect during ops.
                
                SendEvent("connected", new { uuid = uuid });
            } 
            catch (Exception ex) 
            {
                Log("Connection failed: " + ex.Message);
            }
        }

        private static void Device_ConnectionStatusChanged(BluetoothLEDevice sender, object args)
        {
            var uuid = sender.BluetoothAddress.ToString("X");
            if (sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
            {
                if (connectedDevices.ContainsKey(uuid))
                {
                    connectedDevices.Remove(uuid);
                    SendEvent("disconnected", new { uuid = uuid });
                }
            }
        }

        static void Disconnect(string uuid)
        {
            if (connectedDevices.ContainsKey(uuid))
            {
                var device = connectedDevices[uuid];
                device.Dispose(); // Disconnects
                connectedDevices.Remove(uuid);
                SendEvent("disconnected", new { uuid = uuid });
            }
        }

        static async Task DiscoverServices(string uuid, List<string> filter)
        {
            if (!connectedDevices.ContainsKey(uuid)) return;
            var device = connectedDevices[uuid];

            var result = await device.GetGattServicesAsync(BluetoothCacheMode.Uncached);
            
            if (result.Status == GattCommunicationStatus.Success)
            {
                 var services = new List<string>();
                 if (!serviceCache.ContainsKey(uuid)) serviceCache[uuid] = new Dictionary<string, Guid>();

                 foreach (var service in result.Services)
                 {
                     var sUuid = service.Uuid.ToString();
                     // Simplified UUID for standard services? keep full guid.
                     // Node-bluetooth example used 'FFE0' which is short.
                     // Windows returns full GUIDs.
                     // We'll return full GUIDs for consistency, or try to shorten if standard.
                     
                     // For mapping back later:
                     serviceCache[uuid][sUuid] = service.Uuid;
                     services.Add(sUuid);
                 }

                 SendEvent("services", new { uuid = uuid, services = services });
            }
            else
            {
                Log("Failed to get services: " + result.Status);
            }
        }

        static async Task DiscoverCharacteristics(string uuid, string serviceId, List<string> filter)
        {
             if (!connectedDevices.ContainsKey(uuid)) return;
             var device = connectedDevices[uuid];
             
             // Re-find service (could cache service objects explicitly but let's re-fetch for simplicity/robustness)
             if (!serviceCache.ContainsKey(uuid) || !serviceCache[uuid].ContainsKey(serviceId))
             {
                 // Try to parse serviceId as Guid directly if not in cache (e.g. if known common UUID)
                 // Or just fail.
                 // Let's assume DiscoverServices was called first.
             }

             // Parse GUID
             if (!Guid.TryParse(serviceId, out Guid serviceGuid))
             {
                 // Maybe it's a short UUID? 
                 Log("Invalid Service GUID: " + serviceId);
                 return;
             }

             var serviceResult = await device.GetGattServicesForUuidAsync(serviceGuid);
             if (serviceResult.Status != GattCommunicationStatus.Success || serviceResult.Services.Count == 0) return;
             
             var service = serviceResult.Services[0];
             var result = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached);

             if (result.Status == GattCommunicationStatus.Success)
             {
                 var chars = new List<string>();
                 foreach (var c in result.Characteristics)
                 {
                     chars.Add(c.Uuid.ToString());
                 }
                 
                 SendEvent("characteristics", new { uuid = uuid, service = serviceId, characteristics = chars });
             }
        }

        static async Task ReadValue(string uuid, string serviceId, string charId)
        {
             var characteristic = await GetCharacteristic(uuid, serviceId, charId);
             if (characteristic == null) return;

             var result = await characteristic.ReadValueAsync(BluetoothCacheMode.Uncached);
             if (result.Status == GattCommunicationStatus.Success)
             {
                 var reader = DataReader.FromBuffer(result.Value);
                 byte[] bytes = new byte[result.Value.Length];
                 reader.ReadBytes(bytes);
                 string hex = BitConverter.ToString(bytes).Replace("-", "");
                 
                 SendEvent("read", new { uuid = uuid, service = serviceId, characteristic = charId, data = hex });
             }
             else
             {
                 Log("Read failed: " + result.Status);
             }
        }

        static async Task WriteValue(string uuid, string serviceId, string charId, string hexData)
        {
             var characteristic = await GetCharacteristic(uuid, serviceId, charId);
             if (characteristic == null) return;
             
             byte[] data = StringToByteArray(hexData);
             var writer = new DataWriter();
             writer.WriteBytes(data);
             
             var type = characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write) 
                        ? GattWriteOption.WriteWithResponse 
                        : GattWriteOption.WriteWithoutResponse;
             
             var result = await characteristic.WriteValueWithResultAsync(writer.DetachBuffer(), type);
             
             SendEvent("write", new { 
                 uuid = uuid, 
                 service = serviceId, 
                 characteristic = charId, 
                 success = (result.Status == GattCommunicationStatus.Success) 
             });
        }

        // Helper to get characteristic
        static async Task<GattCharacteristic> GetCharacteristic(string uuid, string serviceId, string charId)
        {
            if (!connectedDevices.ContainsKey(uuid)) return null;
            var device = connectedDevices[uuid];
            
            if (!Guid.TryParse(serviceId, out Guid sGuid)) return null;
            if (!Guid.TryParse(charId, out Guid cGuid)) return null;

            var sResult = await device.GetGattServicesForUuidAsync(sGuid);
            if (sResult.Status != GattCommunicationStatus.Success || sResult.Services.Count == 0) return null;
            
            var cResult = await sResult.Services[0].GetCharacteristicsForUuidAsync(cGuid);
            if (cResult.Status != GattCommunicationStatus.Success || cResult.Characteristics.Count == 0) return null;

            return cResult.Characteristics[0];
        }

        static void Log(string msg)
        {
            Console.Error.WriteLine(msg);
        }

        static void SendEvent(string eventName, object data)
        {
            var response = new Response { Event = eventName, data = data };
            var serializer = new DataContractJsonSerializer(typeof(Response));
            
            using (var ms = new MemoryStream())
            {
                serializer.WriteObject(ms, response);
                Console.WriteLine(Encoding.UTF8.GetString(ms.ToArray()));
            }
        }
        
        public static byte[] StringToByteArray(string hex)
        {
            return Enumerable.Range(0, hex.Length)
                             .Where(x => x % 2 == 0)
                             .Select(x => Convert.ToByte(hex.Substring(x, 2), 16))
                             .ToArray();
        }
    }
}
