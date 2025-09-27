import { Injectable } from '@nestjs/common';
import { promises as fs } from 'fs';
import * as path from 'path';
import * as AdmZip from 'adm-zip';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

// Ждём появления файла (используется для manifest.json)
async function waitForFile(filePath: string, timeout = 5000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      await fs.access(filePath);
      return;
    } catch {
      await new Promise((res) => setTimeout(res, 200));
    }
  }
  throw new Error(`Файл ${filePath} не появился за ${timeout} мс`);
}

@Injectable()
export class UploadService {
  // Корень проекта (Amazing-Automata)
  private rootDir = path.join(__dirname, '..', '..', '..');
  private scriptsDir = path.join(this.rootDir, 'ci', 'ci-scripts');

  async saveZip(file: Express.Multer.File) {
    console.log('Получен файл:', file.originalname);

    // Создаём папку project, если её нет
    const projectDir = path.join(this.rootDir, 'project');
    await fs.mkdir(projectDir, { recursive: true });

    // Распаковываем ZIP в rootDir/project
    const zip = new AdmZip(file.buffer);
    zip.extractAllTo(projectDir, true);

    const entries = zip.getEntries().map((e) => e.entryName);
    console.log('Распакованные файлы:', entries);

    const manifestPath = path.join(this.rootDir, 'manifest.json');
    const imageName = 'auto-project:latest';
    const pushFlag = 'true';

    try {
      // 1. Запуск detect-entry.sh (генерирует manifest.json)
      console.log('Запуск detect-entry.sh...');
      const detect = await execAsync(
        `bash ${path.join(this.scriptsDir, 'detect-entry.sh')}`,
        { cwd: this.rootDir } // 🔹 запускаем из корня проекта
      );
      console.log('detect-entry.sh STDOUT:', detect.stdout);
      if (detect.stderr) console.error('detect-entry.sh STDERR:', detect.stderr);

      // ждём появления manifest.json
      await waitForFile(manifestPath);

      // 2. Читаем manifest.json
      const data = await fs.readFile(manifestPath, 'utf-8');
      const manifest = JSON.parse(data);
      console.log('Содержимое manifest.json:', manifest);

      // 3. Запуск docker-build-from-manifest.sh → использует manifest.json
      console.log('Запуск docker-build-from-manifest.sh...');
      const build = await execAsync(
        `bash ${path.join(this.scriptsDir, 'docker-build-from-manifest.sh')} ${manifestPath} ${imageName} ${pushFlag}`,
        { cwd: this.rootDir } // 🔹 запускаем из корня проекта
      );
      console.log('docker-build-from-manifest.sh STDOUT:', build.stdout);
      if (build.stderr) console.error('docker-build-from-manifest.sh STDERR:', build.stderr);

      return { entries, manifest, detect: detect.stdout, build: build.stdout };
    } catch (error) {
      console.error('Ошибка при выполнении скриптов:', error);
      throw new Error('Ошибка при сборке приложения');
    }
  }
}
