import { createApi, fetchBaseQuery } from "@reduxjs/toolkit/query/react";

console.log(import.meta.env.VITE_API_URL)

export const fileApi = createApi({
    reducerPath: "fileApi",
    baseQuery: fetchBaseQuery({ baseUrl: import.meta.env.VITE_API_URL }),
    endpoints: (builder) => ({
        uploadFile: builder.mutation<void, FormData>({
            query: (formData) => ({
                url: "/upload",
                method: "POST",
                body: formData,
            }),
        }),
    }),
});

export const { useUploadFileMutation } = fileApi;
