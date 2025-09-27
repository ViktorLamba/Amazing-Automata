import { Controller, Post, UploadedFile, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { UploadService } from './upload.service';

@Controller('upload')
export class UploadController {
  constructor(private readonly uploadService: UploadService) {}

  @Post('')
  @UseInterceptors(FileInterceptor('file', {
    limits: { fileSize: 75 * 1024 * 1024 * 100 }, // например до 100 файлов/75 МБ на ZIP
  }))
  async uploadFile(@UploadedFile() file: Express.Multer.File) {
    const filenames = await this.uploadService.saveZip(file);
    return { filenames };
  }
}
