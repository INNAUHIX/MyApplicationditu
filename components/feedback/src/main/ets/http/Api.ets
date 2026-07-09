import { FeedbackSubmitDTO } from '../models/FeedbackSubmitDTO';
import { FeedbackRecordDTO } from '../models/FeedbackRecordDTO';

export class Api {
  public static async uploadSingleImage(_uri: string): Promise<string> {
    return '';
  }

  public static async submitFeedback(_dto: FeedbackSubmitDTO): Promise<boolean> {
    return false;
  }

  public static async listFeedbacks(): Promise<FeedbackRecordDTO[]> {
    return [];
  }
}
