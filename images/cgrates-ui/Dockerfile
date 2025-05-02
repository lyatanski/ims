FROM alpine AS build
RUN apk add git nodejs npm
RUN git clone https://github.com/Omnitouch/CGrateS_UI.git
WORKDIR /CGrateS_UI
RUN npm ci
RUN npm run build

FROM nginx:stable-alpine
COPY --from=build /CGrateS_UI/build /usr/share/nginx/html

