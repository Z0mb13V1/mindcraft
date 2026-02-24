import settings from '../settings.js';
import prismarineViewer from 'prismarine-viewer';
const mineflayerViewer = prismarineViewer.mineflayer;

export function addBrowserViewer(bot, count_id) {
    if (settings.render_bot_view)
        mineflayerViewer(bot, { host: '0.0.0.0', port: 3000+count_id, firstPerson: true });
}