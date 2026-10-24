// neuralese_bt: Windows Bluetooth for Neuralese robots, one small tool.
//
//   neuralese_bt scan   [--seconds 8]
//   neuralese_bt pair   --mac 00:16:53:4E:DB:AB [--pin 1234] [--timeout 45]
//   neuralese_bt unpair --mac 00:16:53:4E:DB:AB
//   neuralese_bt repair --mac 00:16:53:4E:DB:AB [--pin 1234] [--timeout 45]
//
// Every command prints exactly one JSON line on stdout; diagnostics go to
// stderr. Ported from the robotics prototype (neuralese-robotics-prototype,
// commit be2a4a5):
//
//   pair    tools/bt_pair.cs, unchanged in behaviour: WinRT custom pairing by
//           MAC, the PIN typed in for the child (ProvidePin) and any
//           confirm-only/confirm-match prompt accepted; an already paired device
//           is left alone and reported as AlreadyPaired. This is what paired
//           KIRISIMA.
//   scan    the idea of tools/bt_helper.ps1 "scan" (watch the radio, report
//           signal strength), but its query found nothing, so this watches
//           paired and unpaired Bluetooth devices instead; see Scan().
//   unpair  tools/bt_helper.ps1 "pair": its first step, UnpairAsync, then
//           500 ms for Windows to settle.
//   repair  unpair (when paired) and pair again: the prototype's bt_helper
//           "pair" action, so a child never has to "forget the device" by hand.
//
// Build: build_neuralese_bt.ps1 (Roslyn csc, .NET Framework 4.8, Windows.winmd).
// .NET Framework 4.8 ships with Windows 10 1903+ and 11, so nothing is installed.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;
using Windows.Foundation;

static class NeuraleseBt
{
    const string PropSignal = "System.Devices.Aep.SignalStrength";
    const string PropPresent = "System.Devices.Aep.IsPresent";
    const string PropConnected = "System.Devices.Aep.IsConnected";
    const string PropPaired = "System.Devices.Aep.IsPaired";
    const string PropAddress = "System.Devices.Aep.DeviceAddress";

    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (args.Length == 0)
            return Fail("usage", "neuralese_bt scan|pair|unpair|repair [--mac M] [--pin P] [--timeout S] [--seconds S]");
        string command = args[0].ToLowerInvariant();
        string mac = Option(args, "--mac", "-Mac", "");
        string pin = Option(args, "--pin", "-Pin", "1234");
        int timeoutSec = IntOption(args, "--timeout", "-Timeout", 45);
        double seconds = DoubleOption(args, "--seconds", null, 8.0);
        try
        {
            switch (command)
            {
                case "scan": return Scan(seconds);
                case "pair": return Pair(mac, pin, timeoutSec);
                case "unpair": return Unpair(mac);
                case "repair": return Repair(mac, pin, timeoutSec);
                default: return Fail("usage", "unknown command " + command);
            }
        }
        catch (Exception ex)
        {
            return Fail("EXCEPTION", ex.Message);
        }
    }

    // -- scan ------------------------------------------------------------------

    static int Scan(double seconds)
    {
        // The prototype's query (AEP ProtocolId for Bluetooth Classic) returns no
        // devices on Windows 11, with or without the AssociationEndpoint kind:
        // measured 2026-10-12. The pairing-state selectors work: paired devices
        // come at once, unpaired ones from a live inquiry over the air.
        string[] props = { PropSignal, PropConnected, PropPaired, PropAddress, PropPresent };
        var found = new ConcurrentDictionary<string, DeviceInformation>();
        var updates = new ConcurrentDictionary<string, Dictionary<string, object>>();
        var watchers = new List<DeviceWatcher>();
        foreach (bool paired in new[] { true, false })
        {
            var watcher = DeviceInformation.CreateWatcher(BluetoothDevice.GetDeviceSelectorFromPairingState(paired), props);
            watcher.Added += (w, d) =>
            {
                if (!string.IsNullOrEmpty(d.Name))
                    found[d.Id] = d;
            };
            watcher.Updated += (w, u) =>
            {
                // Signal strength arrives in updates while the radio keeps hearing the device.
                var bag = updates.GetOrAdd(u.Id, _ => new Dictionary<string, object>());
                lock (bag)
                {
                    foreach (var kv in u.Properties)
                        bag[kv.Key] = kv.Value;
                }
            };
            watchers.Add(watcher);
        }

        foreach (var watcher in watchers)
            watcher.Start();
        Thread.Sleep(TimeSpan.FromSeconds(seconds));
        foreach (var watcher in watchers)
            watcher.Stop();

        var sb = new StringBuilder();
        sb.Append("{\"ok\": true, \"devices\": [");
        bool first = true;
        foreach (var kv in found)
        {
            var d = kv.Value;
            var p = new Dictionary<string, object>();
            foreach (var prop in d.Properties)
                p[prop.Key] = prop.Value;
            Dictionary<string, object> bag;
            if (!updates.TryGetValue(d.Id, out bag))
                bag = null;
            if (bag != null)
                lock (bag)
                    foreach (var u in bag)
                        p[u.Key] = u.Value;

            if (!first) sb.Append(", ");
            first = false;
            sb.Append("{");
            sb.Append("\"id\": ").Append(Json(d.Id)).Append(", ");
            sb.Append("\"name\": ").Append(Json(d.Name)).Append(", ");
            sb.Append("\"address\": ").Append(Json(Get(p, PropAddress) as string)).Append(", ");
            sb.Append("\"paired\": ").Append(Bool(Get(p, PropPaired))).Append(", ");
            sb.Append("\"connected\": ").Append(Bool(Get(p, PropConnected))).Append(", ");
            // Neither IsPresent nor the first signal strength can be trusted:
            // Windows reports a paired device that is switched off as present,
            // with the last strength it ever heard (measured 2026-10-12 with two
            // EV3s that were away). Only a strength the radio reported during
            // this scan is real, and 0, -128 and positive values mean "unknown".
            sb.Append("\"present\": ").Append(Bool(Get(p, PropPresent))).Append(", ");
            sb.Append("\"rssi_cached_dbm\": ").Append(Rssi(d.Properties.ContainsKey(PropSignal) ? d.Properties[PropSignal] : null)).Append(", ");
            object fresh = null;
            if (bag != null)
                lock (bag)
                    bag.TryGetValue(PropSignal, out fresh);
            sb.Append("\"rssi_dbm\": ").Append(Rssi(fresh));
            sb.Append("}");
        }
        sb.Append("]}");
        Console.WriteLine(sb.ToString());
        return 0;
    }

    // -- pair (tools/bt_pair.cs) -------------------------------------------------

    static BluetoothDevice Lookup(string mac)
    {
        if (string.IsNullOrEmpty(mac))
            throw new ArgumentException("--mac is required");
        string cleanMac = mac.Replace(":", "").Replace("-", "").Trim().ToUpperInvariant();
        ulong ulongMac = Convert.ToUInt64(cleanMac, 16);
        var getDevTask = BluetoothDevice.FromBluetoothAddressAsync(ulongMac).AsTask();
        if (!getDevTask.Wait(10000))
            throw new TimeoutException("LOOKUP_TIMEOUT");
        return getDevTask.Result;
    }

    static int Pair(string mac, string pin, int timeoutSec)
    {
        BluetoothDevice dev;
        try { dev = Lookup(mac); }
        catch (AggregateException ex) { return Fail("LOOKUP_FAILED", ex.InnerException != null ? ex.InnerException.Message : ex.Message); }
        catch (TimeoutException) { return Fail("LOOKUP_TIMEOUT", ""); }
        if (dev == null)
            return Fail("DEVICE_NOT_FOUND", "");

        var devInfo = dev.DeviceInformation;
        if (devInfo.Pairing.IsPaired)
            return Ok("AlreadyPaired", dev.Name);

        var custom = devInfo.Pairing.Custom;
        var handler = new TypedEventHandler<DeviceInformationCustomPairing, DevicePairingRequestedEventArgs>((sender, reqArgs) =>
        {
            Console.Error.WriteLine("[neuralese_bt] Pairing event: " + reqArgs.PairingKind);
            try
            {
                if (reqArgs.PairingKind == DevicePairingKinds.ProvidePin)
                {
                    Console.Error.WriteLine("[neuralese_bt] Accepting with PIN");
                    reqArgs.Accept(pin);
                }
                else
                {
                    Console.Error.WriteLine("[neuralese_bt] Accepting without PIN");
                    reqArgs.Accept();
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("[neuralese_bt] Exception: " + ex.Message);
            }
        });
        custom.PairingRequested += handler;

        var kinds = DevicePairingKinds.ProvidePin | DevicePairingKinds.ConfirmOnly | DevicePairingKinds.ConfirmPinMatch;
        var pairTask = custom.PairAsync(kinds).AsTask();
        if (!pairTask.Wait(timeoutSec * 1000))
            return Fail("PAIRING_TIMEOUT", "");

        var res = pairTask.Result;
        bool ok = res.Status == DevicePairingResultStatus.Paired;
        if (ok)
            return Ok(res.Status.ToString(), dev.Name);
        Console.WriteLine("{\"ok\": false, \"status\": " + Json(res.Status.ToString()) + ", \"name\": " + Json(dev.Name) + "}");
        return 1;
    }

    // -- unpair (tools/bt_helper.ps1) ----------------------------------------------

    static int Unpair(string mac)
    {
        BluetoothDevice dev;
        try { dev = Lookup(mac); }
        catch (AggregateException ex) { return Fail("LOOKUP_FAILED", ex.InnerException != null ? ex.InnerException.Message : ex.Message); }
        catch (TimeoutException) { return Fail("LOOKUP_TIMEOUT", ""); }
        if (dev == null)
            return Fail("DEVICE_NOT_FOUND", "");
        string status = UnpairDevice(dev);
        bool ok = status == "Unpaired" || status == "AlreadyUnpaired";
        Console.WriteLine("{\"ok\": " + (ok ? "true" : "false") + ", \"status\": " + Json(status) + ", \"name\": " + Json(dev.Name) + "}");
        return ok ? 0 : 1;
    }

    static string UnpairDevice(BluetoothDevice dev)
    {
        var pairing = dev.DeviceInformation.Pairing;
        if (!pairing.IsPaired)
            return "AlreadyUnpaired";
        var unpairTask = pairing.UnpairAsync().AsTask();
        if (!unpairTask.Wait(15000))
            return "UNPAIR_TIMEOUT";
        Thread.Sleep(500);  // let Windows remove the device and its COM port
        return unpairTask.Result.Status.ToString();
    }

    static int Repair(string mac, string pin, int timeoutSec)
    {
        BluetoothDevice dev;
        try { dev = Lookup(mac); }
        catch (AggregateException ex) { return Fail("LOOKUP_FAILED", ex.InnerException != null ? ex.InnerException.Message : ex.Message); }
        catch (TimeoutException) { return Fail("LOOKUP_TIMEOUT", ""); }
        if (dev == null)
            return Fail("DEVICE_NOT_FOUND", "");
        string unpaired = UnpairDevice(dev);
        Console.Error.WriteLine("[neuralese_bt] Unpair: " + unpaired);
        if (unpaired != "Unpaired" && unpaired != "AlreadyUnpaired")
            return Fail("UNPAIR_FAILED", unpaired);
        dev.Dispose();
        return Pair(mac, pin, timeoutSec);
    }

    // -- helpers -------------------------------------------------------------------

    static object Get(Dictionary<string, object> p, string key)
    {
        object v;
        return p.TryGetValue(key, out v) ? v : null;
    }

    static string Rssi(object v)
    {
        if (v == null) return "null";
        int dbm = Convert.ToInt32(v, CultureInfo.InvariantCulture);
        return (dbm >= 0 || dbm <= -128) ? "null" : dbm.ToString(CultureInfo.InvariantCulture);
    }

    static string Bool(object v)
    {
        return (v is bool && (bool)v) ? "true" : "false";
    }

    static int Ok(string status, string name)
    {
        Console.WriteLine("{\"ok\": true, \"status\": " + Json(status) + ", \"name\": " + Json(name) + "}");
        return 0;
    }

    static int Fail(string error, string detail)
    {
        Console.WriteLine("{\"ok\": false, \"error\": " + Json(error) + ", \"detail\": " + Json(detail) + "}");
        return 1;
    }

    static string Json(string s)
    {
        if (s == null) return "null";
        var sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.AppendFormat("\\u{0:x4}", (int)c);
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }

    static string Option(string[] args, string longName, string shortName, string fallback)
    {
        for (int i = 1; i < args.Length - 1; i++)
            if (args[i] == longName || (shortName != null && string.Equals(args[i], shortName, StringComparison.OrdinalIgnoreCase)))
                return args[i + 1];
        return fallback;
    }

    static int IntOption(string[] args, string longName, string shortName, int fallback)
    {
        int v;
        return int.TryParse(Option(args, longName, shortName, null), out v) ? v : fallback;
    }

    static double DoubleOption(string[] args, string longName, string shortName, double fallback)
    {
        double v;
        return double.TryParse(Option(args, longName, shortName, null), NumberStyles.Float, CultureInfo.InvariantCulture, out v) ? v : fallback;
    }
}
