pkgname=omarchy-spice-guest-tools
pkgver=0.1.2
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
sha256sums=('74834b12f140cdedd2f46ddaab755acfbdff7d4b9549085fa20b3fe976d2969c')

package() {
  cd "${srcdir}/${pkgname}-${pkgver}"
  make DESTDIR="${pkgdir}" PREFIX=/usr install
}
