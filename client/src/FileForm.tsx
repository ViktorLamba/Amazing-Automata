import { Form, Upload, Button, message } from "antd";
import { UploadOutlined } from "@ant-design/icons";
import { useForm } from "antd/es/form/Form";
import JSZip from "jszip";
import { useUploadFileMutation } from "./core/store/api/file.api";

const FileForm = () => {
    const [form] = useForm();
    const [uploadFile, { isLoading }] = useUploadFileMutation();

    const beforeUpload = (file: File) => {
        const isLt75M = file.size / 1024 / 1024 <= 75;
        if (!isLt75M) {
            message.error(`${file.name} превышает 75 МБ!`);
        }
        return isLt75M;
    };

    const normFile = (e: any) => (Array.isArray(e) ? e : e?.fileList);

    const handleSendFiles = async () => {
        const fileList = form.getFieldValue("file") || [];

        if (!Array.isArray(fileList) || fileList.length === 0) {
            message.error("Файлы не загружены!");
            return;
        }

        // Создаём ZIP
        const zip = new JSZip();
        fileList.forEach((fileObj: any) => {
            if (!fileObj.originFileObj) {
                console.warn("Пропущен объект без содержимого:", fileObj.name);
                return; // пропускаем фиктивные файлы
            }

            const relativePath = fileObj.originFileObj.webkitRelativePath || fileObj.name;
            zip.file(relativePath, fileObj.originFileObj);
        });

        const zipBlob = await zip.generateAsync({ type: "blob" });
        const formData = new FormData();
        formData.append("file", zipBlob, "project.zip");

        uploadFile(formData)
            .unwrap()
            .then(() => message.success("Папка загружена!"))
            .catch(() => message.error("Ошибка при загрузке!"));
    };

    return (
        <Form form={form}>
            <Form.Item
                name="file"
                valuePropName="fileList"
                getValueFromEvent={normFile}
            >
                <Upload
                    directory
                    beforeUpload={beforeUpload}
                    multiple
                    customRequest={({ onSuccess }) => onSuccess?.("ok")}
                >
                    <Button icon={<UploadOutlined />}>Выбрать папку</Button>
                </Upload>
            </Form.Item>

            <Button onClick={handleSendFiles} disabled={isLoading}>
                Загрузить
            </Button>
        </Form>
    );
};

export default FileForm;
