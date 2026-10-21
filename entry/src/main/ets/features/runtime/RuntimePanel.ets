import { AppColor, FontSz, Radius, Space } from '../../theme/Theme';

/**
 * 运行状态条（Logcat 顶部）。
 *
 * 一张卡片里同时呈现：连接状态圆点 + 状态文案 + 时长、右侧核心/数据面徽标，
 * 以及（开启测速时）上行/下行两个流量块。每秒刷新——所有展示值必须用 @Prop，
 * 否则父组件 re-render 时子组件冻结在构造初值。详见 arkui-child-component-prop-sync。
 */
@Component
export struct RuntimeStatusBar {
  @Prop statusText: string = '';
  @Prop statusDotColor: ResourceColor = AppColor.textTertiary;
  @Prop durationLabel: string = '';
  @Prop durationValue: string = '';
  @Prop showTraffic: boolean = true;
  @Prop uploadLabel: string = '';
  @Prop uploadValue: string = '';
  @Prop downloadLabel: string = '';
  @Prop downloadValue: string = '';
  @Prop xrayActive: boolean = false;
  @Prop dataPlaneLabel: string = 'TUN';
  @Prop dataPlaneActive: boolean = false;
  // 当前运行内核名（Xray / sing-box），随所选内核变化。
  @Prop coreLabel: string = 'Xray';

  build() {
    Column({ space: Space.md }) {
      Row({ space: Space.sm }) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.statusDotColor)
        Text(this.statusText)
          .fontSize(FontSz.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(`· ${this.durationLabel} ${this.durationValue}`)
          .fontSize(FontSz.footnote)
          .fontColor(AppColor.textTertiary)
        Blank()
        // 徽标的 active 会随刷新变化——不抽 @Builder（按值传参会冻结），直接内联读取 @Prop。
        Row({ space: 3 }) {
          Text(this.coreLabel)
            .fontSize(FontSz.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.xrayActive ? AppColor.brand : AppColor.textTertiary)
          Text(this.xrayActive ? '✓' : '·')
            .fontSize(FontSz.caption)
            .fontColor(this.xrayActive ? AppColor.brand : AppColor.textTertiary)
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.xrayActive ? AppColor.brandTint : AppColor.surfaceAlt)
        .borderRadius(Radius.pill)

        Row({ space: 3 }) {
          Text(this.dataPlaneLabel)
            .fontSize(FontSz.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.dataPlaneActive ? AppColor.brand : AppColor.textTertiary)
          Text(this.dataPlaneActive ? '✓' : '·')
            .fontSize(FontSz.caption)
            .fontColor(this.dataPlaneActive ? AppColor.brand : AppColor.textTertiary)
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.dataPlaneActive ? AppColor.brandTint : AppColor.surfaceAlt)
        .borderRadius(Radius.pill)
      }
      .width('100%')

      if (this.showTraffic) {
        Row({ space: Space.sm }) {
          Column({ space: Space.xs }) {
            Row({ space: Space.xs }) {
              Image($r('app.media.ic_arrow_upward'))
                .width(12)
                .height(12)
                .fillColor(AppColor.info)
              Text(this.uploadLabel)
                .fontSize(FontSz.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textTertiary)
            }
            Text(this.uploadValue)
              .fontSize(FontSz.callout)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.textPrimary)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
          .backgroundColor(AppColor.surfaceAlt)
          .borderRadius(Radius.md)

          Column({ space: Space.xs }) {
            Row({ space: Space.xs }) {
              Image($r('app.media.ic_arrow_downward'))
                .width(12)
                .height(12)
                .fillColor(AppColor.success)
              Text(this.downloadLabel)
                .fontSize(FontSz.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textTertiary)
            }
            Text(this.downloadValue)
              .fontSize(FontSz.callout)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.textPrimary)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
          .backgroundColor(AppColor.surfaceAlt)
          .borderRadius(Radius.md)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Space.lg)
    .backgroundColor(AppColor.surface)
    .borderRadius(Radius.lg)
    .border({ width: 0.5, color: AppColor.border })
  }
}
