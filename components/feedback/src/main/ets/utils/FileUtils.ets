import { common, contextConstant } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';

export class FileUtils {
  private static _context: Context | undefined;

  public static get context(): common.UIAbilityContext {
    return FileUtils._context as common.UIAbilityContext;
  }

  private static _uiContext: UIContext;

  public static get uiContext(): UIContext {
    return FileUtils._uiContext;
  }

  public static async initUIContext(uiContext: UIContext) {
    FileUtils._uiContext = uiContext;
    FileUtils._context = uiContext.getHostContext();
  }

  public static changeAreaMode(area: contextConstant.AreaMode): boolean {
    if (FileUtils.context) {
      FileUtils.context.area = area;
      return true;
    }
    return false;
  }

  public static async saveFileToCache(_srcUriOrPath: string, _area?: contextConstant.AreaMode): Promise<string> {
    return '';
  }

  public static async saveJsonToCache(_obj: ESObject, _filename: string, _area?: contextConstant.AreaMode): Promise<string> {
    return '';
  }

  public static async readJsonFromCache(_filename: string, _area?: contextConstant.AreaMode): Promise<ESObject> {
    return {};
  }
}
