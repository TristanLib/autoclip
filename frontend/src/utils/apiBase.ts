/**
 * API 基础 URL 配置
 * 开发环境：Vite proxy 已将 /api → localhost:8000，所以直接用相对路径
 * 生产环境：Nginx proxy 将 /api → localhost:8000，同样使用相对路径
 *
 * 如需指定外部地址，设置环境变量 VITE_API_BASE_URL
 * 例如：VITE_API_BASE_URL=http://your-server.com
 */
export const API_BASE = (import.meta.env.VITE_API_BASE_URL as string) || ''
