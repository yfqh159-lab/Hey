import {
  CONTROL_CARD_SCAN_URI,
  CONTROL_CARD_START_URI,
  CONTROL_CARD_STOP_URI,
  CONTROL_CARD_TOGGLE_URI,
  buildControlCardFormData
} from '../../core/ControlCard';

let storage = new LocalStorage(buildControlCardFormData());

@Entry(storage)
@Component
struct HeyControlCard {
  @LocalStorageProp('appName') appName: string = 'Hey';
  @LocalStorageProp('subtitle') subtitle: string = 'Quick proxy controls';
  @LocalStorageProp('toggleUri') toggleUri: string = CONTROL_CARD_TOGGLE_URI;
  @LocalStorageProp('startUri') startUri: string = CONTROL_CARD_START_URI;
  @LocalStorageProp('stopUri') stopUri: string = CONTROL_CARD_STOP_URI;
  @LocalStorageProp('scanUri') scanUri: string = CONTROL_CARD_SCAN_URI;
  @LocalStorageProp('statusLabel') statusLabel: string = '';
  @LocalStorageProp('statusDetail') statusDetail: string = '';
  @LocalStorageProp('primaryActionLabel') primaryActionLabel: string = '';
  @LocalStorageProp('primaryActionUri') primaryActionUri: string = CONTROL_CARD_START_URI;
  @LocalStorageProp('cleanupRequired') cleanupRequired: boolean = false;
  @LocalStorageProp('statusColor') statusColor: string = '#9A3412';
  @LocalStorageProp('statusBackground') statusBackground: string = '#FED7AA';
  @LocalStorageProp('primaryColor') primaryColor: string = '#F97316';
  @LocalStorageProp('primaryTextColor') primaryTextColor: string = '#FFFFFF';

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.appName)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1F2937')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Blank()

        Text(this.statusLabel)
          .fontSize(11)
          .fontColor(this.statusColor)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.statusBackground)
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.control_card_title'))
        .fontSize(14)
        .fontColor('#374151')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.statusDetail)
        .fontSize(11)
        .fontColor('#6B7280')
        .lineHeight(15)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 8 }) {
        this.primaryAction(this.primaryActionUri, this.primaryActionLabel, this.primaryColor, this.primaryTextColor)
        this.secondaryAction(this.scanUri)
      }
      .width('100%')

      Row({ space: 8 }) {
        if (this.primaryActionUri !== CONTROL_CARD_STOP_URI && !this.cleanupRequired) {
          this.smallAction(this.startUri, $r('app.string.control_card_start'))
        }
        this.smallAction(this.stopUri, $r('app.string.control_card_stop'))
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#FFF7ED')
  }

  @Builder
  private primaryAction(uri: string, label: string, background: string, textColor: string) {
    FormLink({
      action: 'router',
      uri
    }) {
      Text(label)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(textColor)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(38)
        .lineHeight(38)
        .backgroundColor(background)
        .borderRadius(12)
    }
    .layoutWeight(1)
  }

  @Builder
  private secondaryAction(uri: string) {
    FormLink({
      action: 'router',
      uri
    }) {
      Text($r('app.string.control_card_scan'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#EA580C')
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(38)
        .lineHeight(38)
        .backgroundColor('#FFEDD5')
        .borderRadius(12)
    }
    .layoutWeight(1)
  }

  @Builder
  private smallAction(uri: string, label: ResourceStr) {
    FormLink({
      action: 'router',
      uri
    }) {
      Text(label)
        .fontSize(12)
        .fontColor('#7C2D12')
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(30)
        .lineHeight(30)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .borderWidth(1)
        .borderColor('#FDBA74')
    }
    .layoutWeight(1)
  }
}
