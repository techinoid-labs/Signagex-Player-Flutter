#include <iphlpapi.h>
#include <windows.h>
#include <string>
#include "flutter/method_channel.h"
#include "flutter/standard_method_codec.h"

// Helper function to convert MAC address to a string
std::string GetMacAddress() {
    PIP_ADAPTER_INFO AdapterInfo;
    AdapterInfo = (IP_ADAPTER_INFO*)malloc(sizeof(IP_ADAPTER_INFO));
    DWORD dwBufLen = sizeof(IP_ADAPTER_INFO);

    // Make an initial call to GetAdaptersInfo to get the necessary size into dwBufLen
    if (GetAdaptersInfo(AdapterInfo, &dwBufLen) == ERROR_BUFFER_OVERFLOW) {
        AdapterInfo = (IP_ADAPTER_INFO*)malloc(dwBufLen);
    }

    if (GetAdaptersInfo(AdapterInfo, &dwBufLen) == NO_ERROR) {
        // The MAC address is stored in the Address member of the IP_ADAPTER_INFO structure.
        char mac_addr[18];
        snprintf(mac_addr, sizeof(mac_addr), "%02X:%02X:%02X:%02X:%02X:%02X",
                 AdapterInfo->Address[0], AdapterInfo->Address[1],
                 AdapterInfo->Address[2], AdapterInfo->Address[3],
                 AdapterInfo->Address[4], AdapterInfo->Address[5]);
        free(AdapterInfo);
        return std::string(mac_addr);
    }

    free(AdapterInfo);
    return "Error";
}

// Method Channel implementation
void RegisterMacAddressMethod(flutter::MethodChannel<flutter::EncodableValue>* channel) {
    channel->SetMethodCallHandler(
            [](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
                if (call.method_name().compare("getMacAddress") == 0) {
                    std::string mac_address = GetMacAddress();
                    result->Success(flutter::EncodableValue(mac_address));
                } else {
                    result->NotImplemented();
                }
            });
}