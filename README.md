# FormatBackup - Windows Format Öncesi Sistem Analiz Aracı

Bu araç, bilgisayarınıza format atmadan önce neleri yedeklemeniz gerektiğini analiz eden ve modern bir WPF (Windows Presentation Foundation) arayüzü ile sunan bir PowerShell yardımcı uygulamasıdır. Özellikle yazılımcılar ve güç kullanıcıları (power users) için geliştirici önbellekleri, tarayıcı profilleri, aktif projeler ve sistem yapılandırmalarını listeler.

---

## ⚡ Özellikler

- **Genel Kontrol Paneli:** İşletim sistemi bilgisi, CPU, RAM, GPU (VRAM miktarı dahil), aktif disklerin doluluk oranları (renkli görsel barlar ile) ve kullanıcı yetki seviyesi tespiti.
- **Güvenlik Durumu:** Sistemde aktif olan virüs koruma (Antivirüs) yazılımlarının tespiti.
- **Yüklü Uygulamalar:** Kontrol panelinden yüklenmiş masaüstü uygulamalarını listeler.
- **Windows Mağaza Uygulamaları:** Microsoft Store üzerinden sonradan yüklenmiş uygulamaları (Windows Defender gibi sistem uygulamalarını filtreleyerek) listeler.
- **Geliştirici Önbellekleri:** Gradle, Maven, NuGet, Conda, VS Code eklentileri, Android SDK vb. geliştirici önbelleklerinin diskte kapladığı alanı hesaplar ve yedekleme önerileri sunar. Çift tıklayarak doğrudan dosya konumunu açabilirsiniz.
- **Proje Tespiti:** Belirtilen geliştirme dizinlerindeki projeleri tarar ve teknolojilerine göre (Node.js, Visual Studio, C# Project, Maven, Gradle, IntelliJ, Android Studio, Python, Rust, Unity, Flutter vb.) sınıflandırır.
- **Yedekleme ve Bulut:** OneDrive ve Google Drive senkronizasyon durumları ile tarayıcı profillerinin (Chrome, Edge, Firefox) boyutlarını analiz eder.

---

## 📂 Dosya Yapısı ve Görevleri

Proje dizininde yer alan dosyalar ve işlevleri şunlardır:

1. **`FormatBackupAnalyzer.ps1`**: Arayüzü (WPF) ve arka plandaki tüm sistem analizi süreçlerini (asenkron runspace mimarisiyle) barındıran **ana uygulama dosyasıdır**.
2. **`Run.vbs`**: CMD veya PowerShell konsol ekranı açılmadan, uygulamanın doğrudan **penceresiz ve sessiz bir şekilde başlatılmasını** sağlar. Çift tıklanarak çalıştırılması önerilen dosyadır.
3. **`Run.bat`**: Uygulamayı konsol çıktılarını görerek çalıştırmak veya olası hataları hata ayıklamak için alternatif başlatıcıdır.

---

## 🚀 Çalıştırma

Uygulamayı hiçbir komut satırı işlemi yapmadan çalıştırmak için **`Run.vbs`** dosyasına çift tıklamanız yeterlidir. Uygulama doğrudan şık arayüzüyle karşınıza gelecektir.

---

## ⚙️ Kişiselleştirme (Tarama Dizinlerini Değiştirme)

Varsayılan olarak uygulama `D:\Yazılım etc`, `C:\Development`, `C:\Dev` ve `C:\Projects` dizinlerini ve bunların alt klasörlerini proje taraması için kullanır. Kendi bilgisayarınızdaki proje yollarını eklemek veya değiştirmek isterseniz:

1. **`FormatBackupAnalyzer.ps1`** dosyasını bir metin editörüyle açın.
2. Yaklaşık **750. satıra** gidin.
3. `$extraRoots.Add('C:\KendiKlasörünüz')` şeklinde istediğiniz dizin yollarını ekleyin ya da mevcut varsayılan yolları kendi klasör yapınıza göre düzenleyin.

---

## 🧹 GitHub'a Yüklemeden Önce Silinebilecek Dosyalar

Projeyi GitHub'a yüklemeden önce temiz ve profesyonel bir görünüm elde etmek için aşağıdaki dosyaları elle silebilirsiniz:

- **`cleanup.ps1`**: Kod dosyalarını düzenlemek ve geçici dosyaları silmek için kullanılan yardımcı betiktir. Artık başlatıcılardan (`Run.vbs` ve `Run.bat`) bağımlılığı kaldırılmıştır, bu nedenle güvenle silebilirsiniz.
- **`test_scan.ps1`**: Proje tarama algoritmalarını test etmek için kullanılan geçici bir test betiğidir. Ana uygulamanın çalışması için gerekli değildir.
- **`script_error.log`**: Olası hata loglarını tutan boş bir dosyadır, güvenle silinebilir.

---

## 🔒 Özel/Hassas Bilgi Kontrolü

Kod dosyaları (`FormatBackupAnalyzer.ps1`, `Run.vbs` vb.) içerisinde **hiçbir kişisel veri, kullanıcı adı, şifre, API anahtarı, token veya özel dizin yolu** bulunmamaktadır. 

Tüm analizler ve taramalar, uygulamanın çalıştırıldığı bilgisayarın çevre değişkenleri (`$env:USERPROFILE`, `$env:USERNAME` vb.) ve Windows API'leri (WMI) kullanılarak dinamik olarak gerçekleştirilmektedir. Bu nedenle projeyi GitHub üzerinde açık kaynaklı olarak paylaşmanızda hiçbir güvenlik sakıncası yoktur.
