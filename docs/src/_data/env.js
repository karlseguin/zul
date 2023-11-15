module.exports = {
	prod: process.env.ENV == 'prod',
	baseURL: process.env.BASE_URL || '',
}
