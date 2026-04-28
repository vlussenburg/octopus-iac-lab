FROM nginx:alpine
ARG VERSION=dev
COPY index.html /usr/share/nginx/html/index.html
RUN sed -i "s/window.APP_VERSION || \"dev\"/\"${VERSION}\"/" /usr/share/nginx/html/index.html
EXPOSE 80
