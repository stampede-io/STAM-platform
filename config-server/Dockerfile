# Stage 1: build
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q -DskipTests package

# Stage 2: runtime
FROM eclipse-temurin:21-jre-jammy
RUN useradd -r -u 1001 app
USER 1001
WORKDIR /app
COPY --from=build /src/target/*.jar app.jar
ENV JAVA_TOOL_OPTIONS="-Xmx256m -XX:MaxMetaspaceSize=128m"
EXPOSE 8888
ENTRYPOINT ["java","-jar","app.jar"]
