pkgname=omarchy-spice-guest-tools
pkgver=0.1.1
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
sha256sums=('4452b055acb70bf024ec04e7ec13591e84467f4f359f3812d0907177d5f215dc')

package() {
  cd "${srcdir}/${pkgname}-${pkgver}"
  make DESTDIR="${pkgdir}" PREFIX=/usr install
}
