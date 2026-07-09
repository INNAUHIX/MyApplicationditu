@Entry
@Component
struct MapPage {
  private TAG: string = 'MapPage';
  private mapOptions?: mapCommon.MapOptions;
  private callback?: AsyncCallback<map.MapComponentController>;
  private mapController?: map.MapComponentController;
  private mapEventManager?: map.MapEventManager;

  aboutToAppear(): void {
    this.mapOptions = {
      position: {
        target: {
          latitude: 39.9087,
          longitude: 116.3975
        },
        zoom: 12
      },
      myLocationControlsEnabled: true,
      scaleControlsEnabled: true,
      compassControlsEnabled: true,
      zoomControlsEnabled: true
    };

    this.callback = async (err, mapController) => {
      if (!err) {
        this.mapController = mapController;
        this.mapEventManager = this.mapController.getEventManager();

        let mapLoadCallback = () => {
          console.info(this.TAG, 'on-mapLoad');
        };
        this.mapEventManager.on('mapLoad', mapLoadCallback);

        let cameraChangeCallback = (cameraPosition: map.CameraPosition) => {
          console.info(this.TAG, `on-cameraChange: ${JSON.stringify(cameraPosition)}`);
        };
        this.mapEventManager.on('cameraChange', cameraChangeCallback);
      } else {
        console.error(`Failed to initialize the map, code: ${err.code}, message: ${err.message}`);
      }
    };
  }

  onPageShow(): void {
    if (this.mapController) {
      this.mapController.show();
    }
  }

  onPageHide(): void {
    if (this.mapController) {
      this.mapController.hide();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      MapComponent({ mapOptions: this.mapOptions, mapCallback: this.callback })
        .width('100%')
        .height('100%');

      Row() {
        Column({ space: 8 }) {
          Text('足迹')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White);
          Text('记录你的每一次出发')
            .fontSize(14)
            .fontColor(Color.White)
            .opacity(0.8);
        }
        .padding({ left: 20, bottom: 30 })
        .alignItems(HorizontalAlign.Start);

        Spacer();

        Button('开始记录')
          .width(100)
          .height(40)
          .backgroundColor('#007DFF')
          .borderRadius(20)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .padding({ right: 20, bottom: 30 });
      }
      .width('100%')
      .height(120)
      .backgroundColor('linear-gradient(to top, rgba(0,0,0,0.6), transparent)');
    }
    .width('100%')
    .height('100%');
  }
}

import { MapComponent, mapCommon, map } from '@kit.MapKit';
import { AsyncCallback } from '@kit.BasicServicesKit';