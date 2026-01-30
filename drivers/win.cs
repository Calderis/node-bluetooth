using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.IO;
using System.IO;
using System.Web.Script.Serialization; // JavaScriptSerializer
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using Windows.Foundation;
using System.Runtime.InteropServices.WindowsRuntime; // For EventRegistrationToken

// Compile with: 
// csc /target:exe /out:drivers/win.exe /r:"C:\Program Files (x86)\Windows Kits\10\UnionMetadata\10.0.19041.0\Windows.winmd" /r:"C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETCore\v4.5\System.Runtime.WindowsRuntime.dll" drivers/win.cs
// Note: Paths to Windows.winmd may vary.

namespace NodeBluetooth
{
    public class Command
    {
        public string command;
        public string uuid;
        public List<string> services;
        public string service;
        public List<string> characteristics;
        public string characteristic;
        public string data; // Hex
        public bool? notify;
    }

    public class Response
    {
        public string @event; // reserved word escape or just use name "event" mapping? JavaScriptSerializer matches field names.
        public object data;
    }

    class Program
    {
        class Subscription {
            public GattCharacteristic Characteristic;
            public GattDeviceService Service; // Keep service reference alive!
            public TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> Handler;
        }

        static BluetoothLEAdvertisementWatcher watcher;
        static Dictionary<string, BluetoothLEDevice> connectedDevices = new Dictionary<string, BluetoothLEDevice>();
        static Dictionary<string, Subscription> subscribedCharacteristics = new Dictionary<string, Subscription>();
        static Dictionary<string, Dictionary<string, Guid>> serviceCache = new Dictionary<string, Dictionary<string, Guid>>(); // DeviceID -> { ServiceUUID-String -> ServiceGUID }
        static Dictionary<string, Dictionary<string, GattDeviceService>> serviceObjectCache = new Dictionary<string, Dictionary<string, GattDeviceService>>(); // Keep service objects alive
        static Dictionary<string, Dictionary<string, GattCharacteristic>> characteristicObjectCache = new Dictionary<string, Dictionary<string, GattCharacteristic>>(); // Keep characteristic objects alive
        
        static void Main(string[] args)
        {
            // Set up watcher
            watcher = new BluetoothLEAdvertisementWatcher();
            // Set up watcher
            watcher = new BluetoothLEAdvertisementWatcher();
            watcher.ScanningMode = BluetoothLEScanningMode.Active;
            watcher.Received += OnAdvertisementReceived;
            watcher.Stopped += (s, e) => SendEvent("scanStop", null);

            // Report ready
            SendEvent("stateChange", "poweredOn"); // TODO: Check actual radio state

            // Input loop
            var serializer = new JavaScriptSerializer();
            
            // Allow long lines? buffer?
            // Simple line-based reading
            while (true)
            {
                try
                {
                    string line = Console.ReadLine();
                    if (line == null) break; // EOF
                    if (string.IsNullOrWhiteSpace(line)) continue;

                    var cmd = serializer.Deserialize<Command>(line);
                    HandleCommand(cmd);
                }
                catch (Exception ex)
                {
                    Log("Error parsing command: " + ex.Message);
                }
            }
        }

        static void HandleCommand(Command cmd)
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
                        if (!string.IsNullOrEmpty(cmd.uuid)) Connect(cmd.uuid);
                        break;
                    case "disconnect":
                        if (!string.IsNullOrEmpty(cmd.uuid)) Disconnect(cmd.uuid);
                        break;
                    case "discoverServices":
                        if (!string.IsNullOrEmpty(cmd.uuid)) DiscoverServices(cmd.uuid, cmd.services);
                        break;
                    case "discoverCharacteristics":
                        if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service))
                            DiscoverCharacteristics(cmd.uuid, cmd.service, cmd.characteristics);
                        break;
                    case "read":
                        if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service) && !string.IsNullOrEmpty(cmd.characteristic))
                            ReadValue(cmd.uuid, cmd.service, cmd.characteristic);
                        break;
                    case "write":
                         if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service) && !string.IsNullOrEmpty(cmd.characteristic))
                            WriteValue(cmd.uuid, cmd.service, cmd.characteristic, cmd.data);
                        break;
                    case "subscribe":
                        if (!string.IsNullOrEmpty(cmd.uuid) && !string.IsNullOrEmpty(cmd.service) && !string.IsNullOrEmpty(cmd.characteristic) && cmd.notify != null)
                            Subscribe(cmd.uuid, cmd.service, cmd.characteristic, cmd.notify.Value);
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
            
            // Fallback: If local name is missing, try to get it from the system/cached device object
            // mimicking mac.swift behavior (peripheral.name vs content)
            if (string.IsNullOrEmpty(name))
            {
                try
                {
                    // Note: This is a blocking call on the watcher thread.
                    // Doing this for every unnamed packet might be heavy, but it solves the missing name issue.
                    var device = SyncWait(BluetoothLEDevice.FromBluetoothAddressAsync(args.BluetoothAddress));
                    if (device != null)
                    {
                         if (!string.IsNullOrEmpty(device.Name))
                         {
                             name = device.Name;
                         }
                         device.Dispose();
                    }
                }
                catch { } // Ignore errors fetching device
            }
            var rssi = args.RawSignalStrengthInDBm;
            
            var data = new Dictionary<string, object>
            {
                { "uuid", deviceId },
                { "rssi", rssi },
                { "name", name }
            };

            var services = new List<string>();
            foreach(var uuid in args.Advertisement.ServiceUuids) {
                services.Add(ToShortUuid(uuid));
            }
            data["serviceUuids"] = services;

            SendEvent("device", data);
        }

        static void Connect(string uuid)
        {
            try 
            {
                ulong addr = Convert.ToUInt64(uuid, 16);
                var device = SyncWait(BluetoothLEDevice.FromBluetoothAddressAsync(addr));
                
                if (device == null)
                {
                    Log("Could not find device: " + uuid);
                    return;
                }

                connectedDevices[uuid] = device;
                device.ConnectionStatusChanged += Device_ConnectionStatusChanged;
                
                // Windows doesn't fully "connect" until you do something with GATT.
                // Force connection by requesting GATT services
                var gattResult = SyncWait(device.GetGattServicesAsync(BluetoothCacheMode.Uncached));
                if (gattResult.Status != GattCommunicationStatus.Success)
                {
                    Log("Failed to connect to GATT services: " + gattResult.Status);
                    connectedDevices.Remove(uuid);
                    device.Dispose();
                    return;
                }
                
                // Verify we're actually connected
                if (device.ConnectionStatus != BluetoothConnectionStatus.Connected)
                {
                    Log("Device not connected after GATT request");
                    connectedDevices.Remove(uuid);
                    device.Dispose();
                    return;
                }
                
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
                    // Clean up subscriptions for this device
                    var keysToRemove = subscribedCharacteristics.Keys.Where(k => k.StartsWith(uuid + "/")).ToList();
                    foreach (var key in keysToRemove)
                    {
                        subscribedCharacteristics.Remove(key);
                    }
                    
                    // Clean up caches
                    if (serviceObjectCache.ContainsKey(uuid))
                        serviceObjectCache.Remove(uuid);
                    if (characteristicObjectCache.ContainsKey(uuid))
                        characteristicObjectCache.Remove(uuid);
                    if (serviceCache.ContainsKey(uuid))
                        serviceCache.Remove(uuid);
                    
                    connectedDevices.Remove(uuid);
                    SendEvent("disconnected", new { uuid = uuid });
                }
            }
        }

        static void Disconnect(string uuid)
        {
            if (connectedDevices.ContainsKey(uuid))
            {
                // Clean up subscriptions for this device
                var keysToRemove = subscribedCharacteristics.Keys.Where(k => k.StartsWith(uuid + "/")).ToList();
                foreach (var key in keysToRemove)
                {
                    subscribedCharacteristics.Remove(key);
                }
                
                // Clean up caches
                if (serviceObjectCache.ContainsKey(uuid))
                    serviceObjectCache.Remove(uuid);
                if (characteristicObjectCache.ContainsKey(uuid))
                    characteristicObjectCache.Remove(uuid);
                if (serviceCache.ContainsKey(uuid))
                    serviceCache.Remove(uuid);
                
                var device = connectedDevices[uuid];
                device.Dispose(); // Disconnects
                connectedDevices.Remove(uuid);
                SendEvent("disconnected", new { uuid = uuid });
            }
        }

        static void DiscoverServices(string uuid, List<string> filter)
        {
            if (!connectedDevices.ContainsKey(uuid)) return;
            var device = connectedDevices[uuid];

            var result = SyncWait(device.GetGattServicesAsync(BluetoothCacheMode.Uncached));
            
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

        static void DiscoverCharacteristics(string uuid, string serviceId, List<string> filter)
        {
             BluetoothLEDevice device;
             if (!connectedDevices.TryGetValue(uuid, out device)) return;

             // Parse GUID
             Guid serviceGuid;
             if (!Guid.TryParse(serviceId, out serviceGuid))
             {
                 Log("Invalid Service GUID: " + serviceId);
                 return;
             }

             // Normalize to lowercase for consistent cache keys
             string serviceKey = serviceId.ToLowerInvariant();

             try
             {
                 // Initialize caches if needed (thread-safe check)
                 lock (serviceObjectCache)
                 {
                     if (!serviceObjectCache.ContainsKey(uuid))
                         serviceObjectCache[uuid] = new Dictionary<string, GattDeviceService>(StringComparer.OrdinalIgnoreCase);
                 }
                 lock (characteristicObjectCache)
                 {
                     if (!characteristicObjectCache.ContainsKey(uuid))
                         characteristicObjectCache[uuid] = new Dictionary<string, GattCharacteristic>(StringComparer.OrdinalIgnoreCase);
                 }

                 // Check if still connected
                 if (!connectedDevices.ContainsKey(uuid)) return;

                 // Get or fetch service object and cache it
                 GattDeviceService service;
                 Dictionary<string, GattDeviceService> serviceDict;
                 if (!serviceObjectCache.TryGetValue(uuid, out serviceDict)) return;
                 
                 if (!serviceDict.TryGetValue(serviceKey, out service))
                 {
                     var serviceResult = SyncWait(device.GetGattServicesForUuidAsync(serviceGuid));
                     if (serviceResult.Status != GattCommunicationStatus.Success || serviceResult.Services.Count == 0) 
                     {
                         Log("Failed to get service: " + serviceResult.Status);
                         return;
                     }
                     service = serviceResult.Services[0];
                     if (serviceObjectCache.ContainsKey(uuid))
                         serviceObjectCache[uuid][serviceKey] = service;
                 }
                 
                 var result = SyncWait(service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached));

                 if (result.Status == GattCommunicationStatus.Success)
                 {
                     var chars = new List<string>();
                     foreach (var c in result.Characteristics)
                     {
                         var charUuid = c.Uuid.ToString().ToLowerInvariant();
                         chars.Add(charUuid);
                         
                         // Cache each characteristic object for later use (read/write/subscribe)
                         string charCacheKey = serviceKey + "/" + charUuid;
                         if (characteristicObjectCache.ContainsKey(uuid))
                             characteristicObjectCache[uuid][charCacheKey] = c;
                     }
                     
                     SendEvent("characteristics", new { uuid = uuid, service = serviceId, characteristics = chars });
                 }
                 else
                 {
                     Log("Failed to get characteristics: " + result.Status);
                 }
             }
             catch (KeyNotFoundException)
             {
                 Log("Device disconnected during characteristic discovery");
             }
             catch (Exception ex)
             {
                 Log("Error in DiscoverCharacteristics: " + ex.Message);
             }
        }

        static void ReadValue(string uuid, string serviceId, string charId)
        {
             var characteristic = GetCharacteristic(uuid, serviceId, charId);
             if (characteristic == null) return;

             var result = SyncWait(characteristic.ReadValueAsync(BluetoothCacheMode.Uncached));
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

        static void WriteValue(string uuid, string serviceId, string charId, string hexData)
        {
             var characteristic = GetCharacteristic(uuid, serviceId, charId);
             if (characteristic == null) return;
             
             byte[] data = StringToByteArray(hexData);
             var writer = new DataWriter();
             writer.WriteBytes(data);
             
             var type = characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Write) 
                        ? GattWriteOption.WriteWithResponse 
                        : GattWriteOption.WriteWithoutResponse;
             
             var result = SyncWait(characteristic.WriteValueWithResultAsync(writer.DetachBuffer(), type));
             
             SendEvent("write", new { 
                 uuid = uuid, 
                 service = serviceId, 
                 characteristic = charId, 
                 success = (result.Status == GattCommunicationStatus.Success) 
             });
        }

        static void Subscribe(string uuid, string serviceId, string charId, bool enable)
        {
             string key = uuid + "/" + serviceId + "/" + charId;

             if (!enable)
             {
                 if (subscribedCharacteristics.ContainsKey(key))
                 {
                     var sub = subscribedCharacteristics[key];
                     var c = sub.Characteristic;
                     try {
                        SyncWait(c.WriteClientCharacteristicConfigurationDescriptorAsync(GattClientCharacteristicConfigurationDescriptorValue.None));
                        c.ValueChanged -= sub.Handler;
                     } catch {}
                     subscribedCharacteristics.Remove(key);
                 }
                 return;
             }
             
             // Enable
             GattDeviceService service;
             var characteristic = GetCharacteristicWithService(uuid, serviceId, charId, out service);
             if (characteristic == null) {
                 Log("Subscribe failed: characteristic not found");
                 return;
             }

             // Prefer Notify over Indicate - many devices use Notify
             GattClientCharacteristicConfigurationDescriptorValue value;
             if (characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Notify))
                 value = GattClientCharacteristicConfigurationDescriptorValue.Notify;
             else if (characteristic.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Indicate))
                 value = GattClientCharacteristicConfigurationDescriptorValue.Indicate;
             else {
                 Log("Subscribe failed: characteristic does not support Notify or Indicate");
                 return;
             }

             var status = SyncWait(characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(value));
             
             if (status == GattCommunicationStatus.Success)
             {
                 var handler = new TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs>(Characteristic_ValueChanged);
                 characteristic.ValueChanged += handler;
                 subscribedCharacteristics[key] = new Subscription { Characteristic = characteristic, Service = service, Handler = handler };                 
                 // Send confirmation event
                 SendEvent("notify", new { uuid = uuid, service = serviceId, characteristic = charId, state = true });
             }
             else 
             {
                 Log("Subscribe failed: " + status);
             }
        }

        private static void Characteristic_ValueChanged(GattCharacteristic sender, GattValueChangedEventArgs args)
        {
            var reader = DataReader.FromBuffer(args.CharacteristicValue);
            byte[] bytes = new byte[args.CharacteristicValue.Length];
            reader.ReadBytes(bytes);
            string hex = BitConverter.ToString(bytes).Replace("-", "");

            // We need to find the device UUID. 
            // sender.Service.Device.BluetoothAddress might be accessible if we kept the device open?
            // Or we can just rely on the fact we have the object.
            // Using "X" format for address.
            
            try {
                // Note: Accessing Service.Device here might assume the device is still connected/valid.
                string deviceUuid = sender.Service.Device.BluetoothAddress.ToString("X");
                 SendEvent("read", new { 
                    uuid = deviceUuid, 
                    service = sender.Service.Uuid.ToString(), 
                    characteristic = sender.Uuid.ToString(), 
                    data = hex 
                });
            } catch (Exception ex) {
                Log("Error in ValueChanged: " + ex.Message);
            }
        }

        static GattCharacteristic GetCharacteristic(string uuid, string serviceId, string charId)
        {
            GattDeviceService unusedService;
            return GetCharacteristicWithService(uuid, serviceId, charId, out unusedService);
        }

        static GattCharacteristic GetCharacteristicWithService(string uuid, string serviceId, string charId, out GattDeviceService service)
        {
            service = null;
            if (!connectedDevices.ContainsKey(uuid)) return null;
            var device = connectedDevices[uuid];
            
            Guid sGuid;
            if (!Guid.TryParse(serviceId, out sGuid)) return null;
            Guid cGuid;
            if (!Guid.TryParse(charId, out cGuid)) return null;

            // Normalize to lowercase for consistent cache keys
            string serviceKey = serviceId.ToLowerInvariant();
            string charKey = charId.ToLowerInvariant();

            // Check if we have a cached service object
            if (!serviceObjectCache.ContainsKey(uuid))
                serviceObjectCache[uuid] = new Dictionary<string, GattDeviceService>(StringComparer.OrdinalIgnoreCase);
            
            if (!serviceObjectCache[uuid].ContainsKey(serviceKey))
            {
                var sResult = SyncWait(device.GetGattServicesForUuidAsync(sGuid));
                if (sResult.Status != GattCommunicationStatus.Success || sResult.Services.Count == 0) return null;
                serviceObjectCache[uuid][serviceKey] = sResult.Services[0];
            }
            
            service = serviceObjectCache[uuid][serviceKey];

            // Check if we have a cached characteristic object
            string charCacheKey = serviceKey + "/" + charKey;
            if (!characteristicObjectCache.ContainsKey(uuid))
                characteristicObjectCache[uuid] = new Dictionary<string, GattCharacteristic>(StringComparer.OrdinalIgnoreCase);
            
            if (!characteristicObjectCache[uuid].ContainsKey(charCacheKey))
            {
                var cResult = SyncWait(service.GetCharacteristicsForUuidAsync(cGuid));
                if (cResult.Status != GattCommunicationStatus.Success || cResult.Characteristics.Count == 0) return null;
                characteristicObjectCache[uuid][charCacheKey] = cResult.Characteristics[0];
            }

            return characteristicObjectCache[uuid][charCacheKey];
        }

        static void Log(string msg)
        {
            Console.Error.WriteLine(msg);
        }

        static void SendEvent(string eventName, object data)
        {
            var response = new Dictionary<string, object> { { "event", eventName }, { "data", data } };
            var serializer = new JavaScriptSerializer();
            Console.WriteLine(serializer.Serialize(response));
        }
        
        public static byte[] StringToByteArray(string hex)
        {
            return Enumerable.Range(0, hex.Length)
                             .Where(x => x % 2 == 0)
                             .Select(x => Convert.ToByte(hex.Substring(x, 2), 16))
                             .ToArray();
        }

        static string ToShortUuid(Guid guid)
        {
            string s = guid.ToString();
            if (s.Length == 36 && s.EndsWith("-0000-1000-8000-00805f9b34fb", StringComparison.OrdinalIgnoreCase))
            {
                if (s.StartsWith("0000"))
                {
                    return s.Substring(4, 4);
                }
            }
            return s;
        }

        static T SyncWait<T>(IAsyncOperation<T> op)
        {
            var wait = new ManualResetEvent(false);
            op.Completed = new AsyncOperationCompletedHandler<T>((i, s) => {
                wait.Set();
            });
            wait.WaitOne();
            return op.GetResults();
        }
    }
}
