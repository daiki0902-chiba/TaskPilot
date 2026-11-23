// Pure verification core for a developer-local build. This is NOT a launcher,
// an OS trust provider, or permission to run a GUI. Production admission remains
// blocked until a reviewed collector proves the clean-VM and live-parent facts.
// Compile this source into the local host; never load an unchecked policy DLL
// to establish the initial trust boundary. No certificate store is accessed.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace TaskPilot.LocalValidation
{
    public sealed class HostFacts
    {
        public string Platform { get; private set; }
        public string WindowsFamily { get; private set; }
        public int Build { get; private set; }
        public int ProductType { get; private set; }
        public bool Is64Bit { get; private set; }
        public string PowerShellEdition { get; private set; }
        public int PowerShellMajor { get; private set; }
        public int PowerShellMinor { get; private set; }
        public string Manufacturer { get; private set; }
        public string Model { get; private set; }
        public string EffectivePolicy { get; private set; }
        public string MachineVmBindingSha256 { get; private set; }
        public string UserBindingSha256 { get; private set; }
        public bool? CleanVmProvisioned { get; private set; }
        public bool? NoHostShares { get; private set; }
        public bool? NoHostDataDrives { get; private set; }
        public bool? GuestNetworkDisconnected { get; private set; }
        public bool? ParentPackageLeaseHeldBeforeStart { get; private set; }
        public bool? LiveParentSession { get; private set; }
        public bool? SourceBuiltLocally { get; private set; }

        // A DTO for already-collected facts and pure unit tests. Constructing
        // it cannot establish that any fact is true, nor authorize production.
        public HostFacts(string platform, string windowsFamily, int build, int productType,
            bool is64Bit, string powerShellEdition, int powerShellMajor, int powerShellMinor,
            string manufacturer, string model, string effectivePolicy,
            string machineVmBindingSha256, string userBindingSha256,
            bool? cleanVmProvisioned, bool? noHostShares, bool? noHostDataDrives,
            bool? guestNetworkDisconnected, bool? parentPackageLeaseHeldBeforeStart,
            bool? liveParentSession, bool? sourceBuiltLocally)
        {
            Platform = platform; WindowsFamily = windowsFamily; Build = build;
            ProductType = productType; Is64Bit = is64Bit;
            PowerShellEdition = powerShellEdition; PowerShellMajor = powerShellMajor;
            PowerShellMinor = powerShellMinor; Manufacturer = manufacturer; Model = model;
            EffectivePolicy = effectivePolicy; MachineVmBindingSha256 = machineVmBindingSha256;
            UserBindingSha256 = userBindingSha256; CleanVmProvisioned = cleanVmProvisioned;
            NoHostShares = noHostShares; NoHostDataDrives = noHostDataDrives;
            GuestNetworkDisconnected = guestNetworkDisconnected;
            ParentPackageLeaseHeldBeforeStart = parentPackageLeaseHeldBeforeStart;
            LiveParentSession = liveParentSession; SourceBuiltLocally = sourceBuiltLocally;
        }
    }

    public sealed class PayloadFile
    {
        public string Path { get; private set; }
        public string Sha256 { get; private set; }
        public bool? HeldReadLease { get; private set; }
        public bool? OriginSafe { get; private set; }
        public PayloadFile(string path, string sha256, bool? heldReadLease, bool? originSafe)
        { Path = path; Sha256 = sha256; HeldReadLease = heldReadLease; OriginSafe = originSafe; }
    }

    public sealed class PolicyResult
    {
        public bool CoreVerified { get; private set; }
        public string Code { get; private set; }
        public bool CanLaunch { get { return false; } }
        public bool ProductionAdmissionImplemented { get { return false; } }
        public bool OsTrustChanged { get { return false; } }
        public string Status { get { return CoreVerified ? "CORE_VERIFIED_NOT_READY" : "BLOCKED"; } }
        internal PolicyResult(bool verified, string code) { CoreVerified = verified; Code = code; }
    }

    public static class Policy
    {
        public const string Purpose = "LocalDeveloperValidationSyntheticOnly";
        public const string Version = "0.4.0.2";
        private static readonly string[] ReceiptKeys = {
            "Purpose", "Version", "SourceCommit", "EnvironmentId", "MachineVmBindingSha256",
            "UserBindingSha256", "IssuedUtc", "ExpiresUtc", "PayloadManifestSha256"
        };
        private static readonly string[] RequiredFiles = {
            "TaskPilot.LocalValidation.exe", "local-validation/TaskPilot.LocalValidation.ps1",
            "local-validation/TaskPilot.LocalValidation.Runtime.ps1", "Runtime/TaskPilot.TestSandbox.dll",
            "Codec/TaskPilotMigrationCodec.dll", "Modules/TaskPilot.Storage/TaskPilot.Storage.psm1",
            "Modules/TaskPilot.Storage/provider/System.Data.SQLite.dll",
            "Modules/TaskPilot.Storage/provider/x64/SQLite.Interop.dll",
            "Modules/ImportExcel/ImportExcel.psm1", "Modules/ImportExcel/EPPlus.dll", "schema/001_initial.sql"
        };
        private static readonly Regex Hash = new Regex("\\A[a-f0-9]{64}\\z", RegexOptions.CultureInvariant);
        private static readonly Regex Source = new Regex("\\A[a-f0-9]{40}\\z", RegexOptions.CultureInvariant);
        private static readonly Regex EnvironmentId = new Regex("\\A[a-f0-9]{32}\\z", RegexOptions.CultureInvariant);
        private static PolicyResult Block(string code) { return new PolicyResult(false, code); }

        // Do not accept an "approved" JSON flag, environment variable or caller
        // DTO as production admission. A valid signature only establishes that
        // the pinned local key signed these bytes; it is not public identity or
        // evidence that a VM is clean or that an independent parent still lives.
        public static PolicyResult ProductionAdmission()
        { return Block("TP-LOCAL-PROVISIONING-AND-PARENT-HOST-REQUIRED"); }

        public static PolicyResult Verify(byte[] receiptBytes, byte[] detachedSignature,
            byte[] payloadManifestBytes, string pinnedPublicKeyXml, string expectedSourceCommit,
            HostFacts facts, IEnumerable<PayloadFile> observedPayload, DateTime nowUtc)
        {
            try
            {
                if (receiptBytes == null || detachedSignature == null || payloadManifestBytes == null ||
                    facts == null || observedPayload == null || nowUtc.Kind != DateTimeKind.Utc ||
                    receiptBytes.Length > 8192 || receiptBytes.Length == 0 ||
                    detachedSignature.Length < 256 || detachedSignature.Length > 1024 ||
                    payloadManifestBytes.Length == 0 || payloadManifestBytes.Length > 1048576 ||
                    expectedSourceCommit == null || !Source.IsMatch(expectedSourceCommit))
                    return Block("TP-LOCAL-CORE-INPUT");
                using (RSA key = ReadPublicKey(pinnedPublicKeyXml))
                {
                    if (key == null || !key.VerifyData(receiptBytes, detachedSignature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
                        return Block("TP-LOCAL-RECEIPT-SIGNATURE");
                }
                Dictionary<string, string> receipt = ParseReceipt(receiptBytes);
                if (receipt == null) return Block("TP-LOCAL-RECEIPT-FORMAT");
                if (receipt["Purpose"] != Purpose || receipt["Version"] != Version ||
                    receipt["SourceCommit"] != expectedSourceCommit || !Source.IsMatch(receipt["SourceCommit"]) ||
                    !EnvironmentId.IsMatch(receipt["EnvironmentId"]) ||
                    !Hash.IsMatch(receipt["MachineVmBindingSha256"]) || !Hash.IsMatch(receipt["UserBindingSha256"]) ||
                    !Hash.IsMatch(receipt["PayloadManifestSha256"])) return Block("TP-LOCAL-RECEIPT-SCOPE");
                DateTime issued, expires;
                DateTimeStyles style = DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal;
                if (!DateTime.TryParseExact(receipt["IssuedUtc"], "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture, style, out issued) ||
                    !DateTime.TryParseExact(receipt["ExpiresUtc"], "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture, style, out expires) ||
                    issued > nowUtc || expires <= nowUtc || expires <= issued || (expires - issued).TotalHours > 24)
                    return Block("TP-LOCAL-RECEIPT-LIFETIME");
                if (!SupportedHost(facts)) return Block("TP-LOCAL-CLEAN-CLIENT-VM-REQUIRED");
                // Only pre-existing policy values are observed. No mutation or
                // alternate script execution path is supplied by this component.
                if (facts.EffectivePolicy != "RemoteSigned" && facts.EffectivePolicy != "Unrestricted")
                    return Block("TP-LOCAL-HOST-POLICY-BLOCKED");
                if (facts.CleanVmProvisioned != true || facts.NoHostShares != true ||
                    facts.NoHostDataDrives != true || facts.GuestNetworkDisconnected != true || facts.SourceBuiltLocally != true)
                    return Block("TP-LOCAL-ISOLATION-EVIDENCE-REQUIRED");
                if (facts.ParentPackageLeaseHeldBeforeStart != true || facts.LiveParentSession != true)
                    return Block("TP-LOCAL-LIVE-PARENT-LEASE-REQUIRED");
                if (facts.MachineVmBindingSha256 == null || facts.UserBindingSha256 == null ||
                    !Hash.IsMatch(facts.MachineVmBindingSha256) || !Hash.IsMatch(facts.UserBindingSha256) ||
                    receipt["MachineVmBindingSha256"] != facts.MachineVmBindingSha256 ||
                    receipt["UserBindingSha256"] != facts.UserBindingSha256)
                    return Block("TP-LOCAL-MACHINE-USER-BINDING");
                if (Sha256(payloadManifestBytes) != receipt["PayloadManifestSha256"])
                    return Block("TP-LOCAL-MANIFEST-HASH");
                Dictionary<string, string> expected = ParseManifest(payloadManifestBytes);
                if (expected == null) return Block("TP-LOCAL-MANIFEST-FORMAT");
                HashSet<string> observed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                int count = 0;
                foreach (PayloadFile file in observedPayload)
                {
                    if (++count > 2048 || file == null || !ValidPath(file.Path) || !observed.Add(file.Path) ||
                        file.Sha256 == null || !Hash.IsMatch(file.Sha256) || !expected.ContainsKey(file.Path) ||
                        expected[file.Path] != file.Sha256) return Block("TP-LOCAL-PAYLOAD-INTEGRITY");
                    if (file.HeldReadLease != true || file.OriginSafe != true)
                        return Block("TP-LOCAL-PAYLOAD-LEASE-OR-ORIGIN");
                }
                if (count != expected.Count) return Block("TP-LOCAL-PAYLOAD-INVENTORY");
                return new PolicyResult(true, "TP-LOCAL-CORE-VERIFIED-PRODUCTION-BLOCKED");
            }
            catch (Exception)
            {
                // Never disclose receipt fields, paths, host bindings, raw
                // cryptographic/XML exceptions, or any caller-provided values.
                return Block("TP-LOCAL-CORE-VALIDATION-FAILED");
            }
        }

        private static bool SupportedHost(HostFacts f)
        {
            bool clientBuild = (f.WindowsFamily == "Windows10" && f.Build >= 10240 && f.Build <= 19045) ||
                (f.WindowsFamily == "Windows11" && f.Build >= 22000);
            return f.Platform == "Win32NT" && clientBuild && f.ProductType == 1 && f.Is64Bit &&
                f.PowerShellEdition == "Desktop" && f.PowerShellMajor == 5 && f.PowerShellMinor == 1 &&
                f.Manufacturer == "Microsoft Corporation" && f.Model == "Virtual Machine";
        }
        private static string[] Lines(byte[] bytes)
        {
            if (bytes.Length == 0 || bytes[bytes.Length - 1] != 10) return null;
            foreach (byte value in bytes) if (value > 126 || (value < 32 && value != 10)) return null;
            string[] lines = Encoding.ASCII.GetString(bytes).Split('\n');
            if (lines[lines.Length - 1] != "") return null;
            return lines;
        }
        private static Dictionary<string, string> ParseReceipt(byte[] bytes)
        {
            string[] lines = Lines(bytes);
            if (lines == null || lines.Length != ReceiptKeys.Length + 2 || lines[0] != "TASKPILOT-LOCAL-RECEIPT-1") return null;
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int index = 0; index < ReceiptKeys.Length; index++)
            {
                string prefix = ReceiptKeys[index] + "=";
                if (!lines[index + 1].StartsWith(prefix, StringComparison.Ordinal)) return null;
                string value = lines[index + 1].Substring(prefix.Length);
                if (value.Length == 0 || value.IndexOf('=') >= 0) return null;
                values.Add(ReceiptKeys[index], value);
            }
            return values;
        }
        private static Dictionary<string, string> ParseManifest(byte[] bytes)
        {
            string[] lines = Lines(bytes);
            if (lines == null || lines.Length < RequiredFiles.Length + 4 || lines.Length > 2052 ||
                lines[0] != "TASKPILOT-LOCAL-MANIFEST-1" || lines[1] != "Purpose=" + Purpose || lines[2] != "Version=" + Version) return null;
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            HashSet<string> aliases = new HashSet<string>(StringComparer.OrdinalIgnoreCase); string previous = null;
            for (int index = 3; index < lines.Length - 1; index++)
            {
                string line = lines[index];
                if (!line.StartsWith("File=", StringComparison.Ordinal) || line.Length < 71 || line[69] != ' ') return null;
                string hash = line.Substring(5, 64), name = line.Substring(70);
                if (!Hash.IsMatch(hash) || !ValidPath(name) || !aliases.Add(name) ||
                    (previous != null && StringComparer.Ordinal.Compare(previous, name) >= 0)) return null;
                values.Add(name, hash); previous = name;
            }
            foreach (string required in RequiredFiles) if (!values.ContainsKey(required)) return null;
            return values;
        }
        private static bool ValidPath(string path)
        {
            if (path == null || path.Length == 0 || path.Length > 240 ||
                !Regex.IsMatch(path, "\\A[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\\z", RegexOptions.CultureInvariant)) return false;
            foreach (string part in path.Split('/'))
            {
                if (part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) ||
                    Regex.IsMatch(part, "\\A(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|\\z)")) return false;
            }
            string leaf = path.Substring(path.LastIndexOf('/') + 1);
            if (String.Equals(leaf, "TaskPilot.exe", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(leaf, "TaskPilot.ps1", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(leaf, "TaskPilot.Acceptance.exe", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(leaf, "TaskPilot.Acceptance.ps1", StringComparison.OrdinalIgnoreCase)) return false;
            if (Regex.IsMatch(path, "(?:\\A|/)(?i:Data|Backup|Export|Logs|Temp|Input|DeveloperSandbox|TestResults|tests|reference)(?:/|\\z)") ||
                Regex.IsMatch(leaf, "(?i:\\.(?:db|sqlite|sqlite3)(?:-(?:journal|wal|shm))?|\\.(?:log|bak|tmp))\\z")) return false;
            return true;
        }
        private static string Sha256(byte[] bytes)
        {
            using (SHA256 digest = SHA256.Create()) return BitConverter.ToString(digest.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
        }
        private static RSA ReadPublicKey(string xml)
        {
            if (xml == null || xml.Length == 0 || xml.Length > 16384) return null;
            XmlReaderSettings settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
            XmlDocument document = new XmlDocument(); document.XmlResolver = null;
            using (XmlReader reader = XmlReader.Create(new StringReader(xml), settings)) document.Load(reader);
            XmlElement root = document.DocumentElement;
            if (root == null || root.Name != "RSAKeyValue" || root.NamespaceURI != "" || root.HasAttributes || root.ChildNodes.Count != 2) return null;
            string modulus = null, exponent = null;
            foreach (XmlNode node in root.ChildNodes)
            {
                XmlElement item = node as XmlElement;
                if (item == null || item.NamespaceURI != "" || item.HasAttributes || item.ChildNodes.Count != 1 || item.FirstChild.NodeType != XmlNodeType.Text) return null;
                if (item.Name == "Modulus" && modulus == null) modulus = item.InnerText;
                else if (item.Name == "Exponent" && exponent == null) exponent = item.InnerText;
                else return null;
            }
            if (modulus == null || exponent == null) return null;
            byte[] n = Convert.FromBase64String(modulus), e = Convert.FromBase64String(exponent);
            if (n.Length < 256 || n.Length > 1024 || e.Length != 3 || e[0] != 1 || e[1] != 0 || e[2] != 1) return null;
            RSA key;
            if (Environment.OSVersion.Platform == PlatformID.Win32NT)
            {
                CspParameters parameters = new CspParameters(24); // PROV_RSA_AES supports SHA-256.
                parameters.Flags = CspProviderFlags.CreateEphemeralKey;
                RSACryptoServiceProvider ephemeral = new RSACryptoServiceProvider(parameters);
                ephemeral.PersistKeyInCsp = false; key = ephemeral;
            }
            else key = RSA.Create();
            try { key.ImportParameters(new RSAParameters { Modulus = n, Exponent = e }); return key; }
            catch { key.Dispose(); throw; }
        }
    }
}
