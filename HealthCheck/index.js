module.exports = async function (context, req) {
    context.log('Health check function executed');

    return {
        status: 200,
        body: {
            status: "healthy",
            message: "Azure VM Health Assistant API is running"
        }
    };
};