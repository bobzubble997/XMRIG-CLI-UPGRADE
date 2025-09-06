📖 Panduan Lengkap Pemakaian xmrig_auto.sh

Script xmrig_auto.sh adalah installer sekaligus launcher XMRig multi-instance untuk menambang Monero (XMR).
Script ini bisa berjalan di Linux (Ubuntu, Debian, Fedora, Arch, dll.) maupun Termux (Android).


---

1. Persiapan Awal

A. Install Git & Build Tools (jika belum ada)

Ubuntu/Debian:


sudo apt update -y
sudo apt install -y git build-essential cmake automake libtool autoconf libhwloc-dev libuv1-dev libssl-dev curl wget jq

Fedora/CentOS:


sudo dnf install -y git gcc gcc-c++ cmake automake libtool autoconf hwloc-devel libuv-devel openssl-devel make wget curl jq

Arch Linux:


sudo pacman -S --needed --noconfirm git base-devel cmake hwloc libuv openssl wget curl jq

Termux (Android):


pkg update -y
pkg install -y git build-essential cmake automake libtool autoconf hwloc libuv openssl wget curl tar jq


---

2. Unduh Script

Masuk ke folder kerja, lalu buat file script:

nano xmrig_auto.sh

Paste isi script penuh yang sudah kuberikan. Simpan (CTRL+O, Enter) lalu keluar (CTRL+X).

Beri izin eksekusi:

chmod +x xmrig_auto.sh


---

3. Jalankan Script

Jalankan dengan:

./xmrig_auto.sh

Kamu akan ditanya beberapa hal:

1. Wallet Monero (XMR)
Masukkan alamat wallet milikmu (dimulai dengan 4... atau 8...).


2. Pilih pool
Akan muncul menu seperti:

1) pool.supportxmr.com:3333
2) pool.moneroocean.stream:10128
3) de.monero.herominers.com:1111
4) p2pool.io:3333
5) Custom pool

Kamu bisa pilih lebih dari 1 (misal 1,3).

Kalau pilih 5, kamu bisa ketik pool custom sendiri (host:port).



3. Simpan pool
Kalau jawab y, daftar pool akan disimpan ke xmrig_auto_install/pools.conf.


4. Jumlah threads
Kalau Enter saja, otomatis pakai jumlah core CPU (nproc).


5. Background mode?

y = jalan di background, log disimpan ke folder xmrig_auto_install/logs/.

n = jalan di foreground, langsung kelihatan output di terminal.





---

4. Monitoring

Jika background mode:

Log tiap instance ada di:

xmrig_auto_install/logs/xmrig_pool_1.log
xmrig_auto_install/logs/xmrig_pool_2.log

Balance checker (jika pool mendukung API) dicatat di:

xmrig_auto_install/logs/balance.log


Cek apakah miner jalan:


ps aux | grep xmrig

Lihat log realtime:


tail -f xmrig_auto_install/logs/xmrig_pool_1.log


---

5. Menghentikan Miner

Untuk memberhentikan semua proses miner + balance checker:

./xmrig_auto.sh stop


---

6. Catatan Penting

Optimasi: Script mencoba aktifkan msr module + hugepages (1GB/2MB). Jika tidak berhasil, miner tetap jalan tanpa optimasi.

Donasi dev: Script default pakai --donate-level=1.

Etika: Gunakan hanya di perangkat milikmu (jangan di server / PC orang lain tanpa izin).

Reward: Lihat reward di dashboard pool:

supportxmr → https://supportxmr.com/

moneroocean → https://moneroocean.stream/

herominers → https://monero.herominers.com/




---

7. Quick Commands

Jalankan script:


./xmrig_auto.sh

Stop semua miner:


./xmrig_auto.sh stop

Lihat log mining:


tail -f xmrig_auto_install/logs/xmrig_pool_1.log

Lihat saldo pool:


tail -f xmrig_auto_install/logs/balance.log


---

🎯 Dengan panduan ini, kamu bisa install, menjalankan, memantau, dan menghentikan mining dengan aman dan mudah.
