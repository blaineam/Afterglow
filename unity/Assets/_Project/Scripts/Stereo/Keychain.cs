using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Afterglow.Stereo
{
    // The phone's Keychain (Plugins/iOS/AfterglowKeychain.mm), for the browser's saved logins:
    // a secret per service (the site's host) and account (the username), kept by iOS, readable
    // only while the phone is unlocked and never leaving it. Nothing here logs a secret. Off iOS
    // there is no keychain and every call says so.
    public static class Keychain
    {
        const int k_SecretLength = 1024;
        const int k_AccountsLength = 4096;

        public static bool Supported =>
#if UNITY_IOS && !UNITY_EDITOR
            true;
#else
            false;
#endif

        public static bool Store(string service, string account, string secret)
        {
            if (string.IsNullOrEmpty(service) || string.IsNullOrEmpty(account) || secret == null)
                return false;
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_KeychainStore(service, account, secret) == 1;
#else
            return false;
#endif
        }

        public static bool TryLoad(string service, string account, out string secret)
        {
            secret = null;
            if (string.IsNullOrEmpty(service) || string.IsNullOrEmpty(account))
                return false;
#if UNITY_IOS && !UNITY_EDITOR
            var buffer = new StringBuilder(k_SecretLength);
            var result = Afterglow_KeychainLoad(service, account, buffer, buffer.Capacity);
            if (result < 0)
            {
                buffer = new StringBuilder(-result + 1);
                result = Afterglow_KeychainLoad(service, account, buffer, buffer.Capacity);
            }
            if (result != 1)
                return false;
            secret = buffer.ToString();
            return true;
#else
            return false;
#endif
        }

        public static bool Delete(string service, string account)
        {
#if UNITY_IOS && !UNITY_EDITOR
            return Afterglow_KeychainDelete(service, account) == 1;
#else
            return false;
#endif
        }

        // The accounts saved for a service.
        public static string[] Accounts(string service)
        {
            if (string.IsNullOrEmpty(service))
                return Array.Empty<string>();
#if UNITY_IOS && !UNITY_EDITOR
            var buffer = new StringBuilder(k_AccountsLength);
            if (Afterglow_KeychainAccounts(service, buffer, buffer.Capacity) <= 0)
                return Array.Empty<string>();
            return buffer.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries);
#else
            return Array.Empty<string>();
#endif
        }

        // Stores, reads back and deletes a throwaway secret, and says how it went: the
        // keychainTest launch option, for a build whose entitlement is in doubt (the Simulator
        // answers -34018 without one). Logs no secret.
        public static void SelfTest()
        {
            const string service = "afterglow.self-test";
            const string account = "tester";
            if (!Supported)
            {
                UnityEngine.Debug.Log("[Keychain] Self-test: no keychain here");
                return;
            }
            var stored = Store(service, account, "s3cret-" + DateTime.UtcNow.Ticks);
            var read = TryLoad(service, account, out var back) && back.StartsWith("s3cret-");
            var accounts = Accounts(service);
            var deleted = Delete(service, account);
            UnityEngine.Debug.Log($"[Keychain] Self-test: stored {stored}, read back {read}, {accounts.Length} account(s) listed, deleted {deleted}");
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int Afterglow_KeychainStore(string service, string account, string secret);
        [DllImport("__Internal")] static extern int Afterglow_KeychainLoad(string service, string account, StringBuilder buffer, int capacity);
        [DllImport("__Internal")] static extern int Afterglow_KeychainDelete(string service, string account);
        [DllImport("__Internal")] static extern int Afterglow_KeychainAccounts(string service, StringBuilder buffer, int capacity);
#endif
    }
}
