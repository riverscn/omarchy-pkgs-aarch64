pkgname=omarchy-spice-guest-tools
pkgver=0.1.4
pkgrel=1
pkgdesc='System-packaged, per-user SPICE integration for Omarchy'
url='https://github.com/riverscn/omarchy-spice-guest-tools'
arch=('aarch64' 'x86_64')
license=('MIT')
install=omarchy-spice-guest-tools.install
depends=(
  'bash'
  'clipnotify'
  'coreutils'
  'gawk'
  'gdk-pixbuf2'
  'glib2'
  'gtk3'
  'hyprland'
  'jq'
  'libxcvt'
  'spice-vdagent'
  'systemd'
  'util-linux'
  'wayland'
  'wl-clipboard'
  'xclip'
)
makedepends=(
  'pkgconf'
  'wayland-protocols'
)
source=("${pkgname}-${pkgver}.tar.gz::${url}/releases/download/v${pkgver}/${pkgname}-${pkgver}.tar.gz")
sha256sums=('073840c82d53740b13c47cf35a6a7e4992b06ad352c277ef0617d0b9597becf3')

build() {
  cd "${srcdir}/${pkgname}-${pkgver}"
  make
}

check() {
  cd "${srcdir}/${pkgname}-${pkgver}"
  make check
}

package() {
  cd "${srcdir}/${pkgname}-${pkgver}"
  make DESTDIR="${pkgdir}" PREFIX=/usr install
}
