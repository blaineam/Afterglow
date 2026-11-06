// The iOS Keychain, for the browser's saved logins: a secret per (service, account), readable
// only while the phone is unlocked and only on this phone (kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
// so it is never in a backup or in iCloud Keychain). The browser's service is the site's host;
// the account is the username. Secrets go in and out as UTF-8 and are never logged.
// Keychain.cs is the C# side.

#import <Foundation/Foundation.h>
#import <Security/Security.h>

void AGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

namespace
{
    NSMutableDictionary *Query(const char *service, const char *account)
    {
        NSMutableDictionary *query = [NSMutableDictionary new];
        query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
        query[(__bridge id)kSecAttrService] = [NSString stringWithUTF8String:service];
        if (account != nullptr)
            query[(__bridge id)kSecAttrAccount] = [NSString stringWithUTF8String:account];
        return query;
    }
}

// Stores or replaces the secret. 1 on success.
extern "C" int Afterglow_KeychainStore(const char *service, const char *account, const char *secret)
{
    if (service == nullptr || account == nullptr || secret == nullptr)
        return 0;
    NSData *data = [[NSString stringWithUTF8String:secret] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *query = Query(service, account);
    NSDictionary *update = @{ (__bridge id)kSecValueData: data };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    if (status == errSecItemNotFound)
    {
        query[(__bridge id)kSecValueData] = data;
        query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)query, nullptr);
    }
    if (status != errSecSuccess)
        AGLog(@"[Keychain] Couldn't store the login for %s: %d", service, (int)status);
    return status == errSecSuccess ? 1 : 0;
}

// The secret, copied into the buffer: 1 and the secret, 0 if there is none (or the buffer is
// too small, in which case the needed length is returned negated).
extern "C" int Afterglow_KeychainLoad(const char *service, const char *account, char *buffer, int capacity)
{
    if (service == nullptr || account == nullptr)
        return 0;
    NSMutableDictionary *query = Query(service, account);
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == nullptr)
        return 0;
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *secret = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    const char *utf8 = secret.UTF8String;
    const int needed = (int)strlen(utf8);
    if (buffer == nullptr || capacity <= needed)
        return -needed;
    strlcpy(buffer, utf8, (size_t)capacity);
    return 1;
}

extern "C" int Afterglow_KeychainDelete(const char *service, const char *account)
{
    if (service == nullptr || account == nullptr)
        return 0;
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)Query(service, account));
    return status == errSecSuccess || status == errSecItemNotFound ? 1 : 0;
}

// The accounts stored for a service, newline-separated, into the buffer: how many there are.
extern "C" int Afterglow_KeychainAccounts(const char *service, char *buffer, int capacity)
{
    if (service == nullptr)
        return 0;
    NSMutableDictionary *query = Query(service, nullptr);
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    CFTypeRef result = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == nullptr)
        return 0;
    NSArray *items = (__bridge_transfer NSArray *)result;
    NSMutableArray<NSString *> *accounts = [NSMutableArray new];
    for (NSDictionary *item in items)
    {
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if (account.length > 0)
            [accounts addObject:account];
    }
    if (buffer != nullptr && capacity > 0)
        strlcpy(buffer, [accounts componentsJoinedByString:@"\n"].UTF8String, (size_t)capacity);
    return (int)accounts.count;
}
