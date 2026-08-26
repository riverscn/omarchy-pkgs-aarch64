pkgname=omarchy-spice-guest-tools
pkgver=0.1.0
pkgrel=1
pkgdesc='System-packaged, per-user SPICE integration for Omarchy'
url='https://github.com/riverscn/omarchy-spice-guest-tools'
arch=('any')
license=('MIT')
install=omarchy-spice-guest-tools.install
depends=(
  'bash'
  'clipnotify'
  'coreutils'
  'gawk'
  'hyprland'
  'jq'
  'libxcvt'
  'spice-vdagent'
  'systemd'
  'util-linux'
  'wl-clipboard'
  'xclip'
)
source=("${pkgname}-${pkgver}.tar.gz::${url}/releases/download/v${pkgver}/${pkgname}-${pkgver}.tar.gz")
sha256sums=('c2027e9914ff92af59682029188da09fe46cabb232bf036be6be2956f01c2a0e')

package() {
  cd "${srcdir}/${pkgname}-${pkgver}"
  make DESTDIR="${pkgdir}" PREFIX=/usr install
}
