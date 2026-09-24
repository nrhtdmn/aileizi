# Google Sign-In (hata 10 / DEVELOPER_ERROR)

Release APK şu an **debug keystore** ile imzalanıyor. Firebase’e bu SHA-1 eklenmeli:

```
SHA-1: E4:CC:1C:F7:88:DB:58:0D:D7:F2:A2:A8:4B:2E:11:C7:24:69:90:04
SHA-256: B8:C4:F5:15:D3:DF:20:3A:D9:62:E1:0F:B4:CA:E4:75:B5:90:D3:CA:4E:D7:75:0B:2C:09:1A:DE:E8:B1:BC:99
```

## Adımlar
1. [Firebase Console](https://console.firebase.google.com) → proje `aile-takip-8bf84`
2. Project settings → Your apps → Android (`com.senin.parent`)
3. **Add fingerprint** → SHA-1 (ve mümkünse SHA-256) yapıştır
4. Google Sign-In / Authentication’da Google sağlayıcısı açık olsun
5. Yeni `google-services.json` indirip `parent_app/android/app/` altına koy
6. Uygulamayı yeniden derle / yükle
