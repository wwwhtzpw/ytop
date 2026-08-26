#!/bin/bash
# 智能菜单执行脚本：支持 &变量 &&变量 交互式替换
# 修复达梦/openGauss等数据库 error:2
# 目录：绿色、升序、屏蔽common/log
# 帮助：./menu.sh -h
# 修复：特殊字符文件名导致 awk 报错问题
# 新增：支持查看 .md 格式文件

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
COMMON_DIR="${SCRIPT_DIR}/common"
DIR_DESC_FILE="${COMMON_DIR}/dirdesc.pro"
FILE_DESC_FILE="${COMMON_DIR}/filedesc.pro"
ENV_CONFIG="${COMMON_DIR}/config.env"
README_MD="${SCRIPT_DIR}/README.md"
README_TXT="${SCRIPT_DIR}/README"

# 颜色
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

# ===================== 系统信息收集（全Linux兼容） =====================
get_system_info() {
    # Java版本
    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | head -n1)
    else
        JAVA_VERSION="未安装"
    fi

    # OpenSSL版本
    if command -v openssl &>/dev/null; then
        OPENSSL_VERSION=$(openssl version | awk '{print $2}')
    else
        OPENSSL_VERSION="未安装"
    fi

    # 磁盘信息（取根目录挂载点）
    DISK_USAGE=$(df -h / | awk 'NR==2{print "总大小:"$2" 剩余:"$4" 使用率:"$5}')

    # 统一获取真实磁盘（笔记本 NVMe / LVM / SATA 通用）
    DISK_TYPE="未知"
    if [ -x /usr/bin/lsblk ]; then
        # lsblk 方式最稳，直接识别 rotational = 0/1
        DEV=$(lsblk -no pkname / 2>/dev/null | head -1)
        if [ -n "$DEV" ] && [ -b "/dev/$DEV" ]; then
            rot=$(cat "/sys/block/$DEV/queue/rotational" 2>/dev/null)
            if [ "$rot" = "0" ]; then
                DISK_TYPE="SSD"
            elif [ "$rot" = "1" ]; then
                DISK_TYPE="HDD"
            fi
        fi
    else
        # 兼容无 lsblk 的极简系统
        ROOT_DEV=$(df / | awk 'NR==2{print $1}')
        DEV=$(basename "$ROOT_DEV" | sed -E 's/[0-9]+$//g')
        if [ -f "/sys/block/$DEV/queue/rotational" ]; then
            rot=$(cat "/sys/block/$DEV/queue/rotational")
            DISK_TYPE=$([ "$rot" = "0" ] && echo "SSD" || echo "HDD")
        fi
    fi

    DISK_INFO="${DISK_USAGE} 类型:${DISK_TYPE}"
}
# ===================== -h 帮助 =====================
if [ "$1" = "-h" ]; then
    if [ -f "$README_MD" ]; then
        cat "$README_MD"
    elif [ -f "$README_TXT" ]; then
        cat "$README_TXT"
    else
        echo -e "${RED}错误：未找到帮助文件${RESET}"
    fi
    exit 0
fi

# ===================== 检查配置 =====================
check_config() {
    if [ ! -d "$COMMON_DIR" ]; then
        echo -e "${RED}错误：配置目录 ${COMMON_DIR} 不存在！${RESET}"; exit 1
    fi
    if [ ! -f "$DIR_DESC_FILE" ]; then
        echo -e "${RED}错误：${DIR_DESC_FILE} 不存在！${RESET}"; exit 1
    fi
    if [ ! -f "$FILE_DESC_FILE" ]; then
        echo -e "${RED}错误：${FILE_DESC_FILE} 不存在！${RESET}"; exit 1
    fi
    if [ ! -f "$ENV_CONFIG" ]; then
        echo -e "${YELLOW}警告：SQL配置文件 ${ENV_CONFIG} 不存在，SQL无法执行${RESET}"
    fi
}

# ===================== 读取描述（安全写法，彻底解决特殊字符文件名报错） =====================
get_dir_desc() {
    local dir_name="$1"
    awk -v name="$dir_name" -F '=' '!/^#/ && $1 == name {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$DIR_DESC_FILE"
}

get_file_desc() {
    local file_name="$1"
    awk -v name="$file_name" -F '=' '!/^#/ && $1 == name {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$FILE_DESC_FILE"
}
# ===================== 加载SQL命令 =====================
load_sql_command() {
    if [ ! -f "$ENV_CONFIG" ]; then return 1; fi
    set -o allexport
    source "$ENV_CONFIG"
    set +o allexport

    # 检查必填项
    if [ -z "$DB_CMD" ] || [ -z "$DB_HOST" ] || [ -z "$DB_PORT" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ]; then
        return 1
    fi

    # 自动拼接完整执行命令（适配达梦/openGauss/MySQL）
    SQL_EXEC_CMD="${DB_CMD}  ${DB_USER}/${DB_PASS}@${DB_HOST}:${DB_PORT} -f -e"

    return 0
}

# ===================== 主菜单（欢迎信息融合版） =====================
show_main_menu() {
    clear
    get_system_info

    echo -e "${BLUE}=========================================================${RESET}"
    echo -e "${GREEN}               YAS运维工具${RESET}"
    echo -e "${BLUE}=========================================================${RESET}"
    echo -e "${YELLOW}📌 环境信息：${RESET}"
    echo -e "  Java版本    : ${GREEN}$JAVA_VERSION${RESET}"
    echo -e "  OpenSSL版本 : ${GREEN}$OPENSSL_VERSION${RESET}"
    echo -e "  磁盘状态    : ${GREEN}$DISK_INFO${RESET}"
    echo -e "  脚本目录    : ${GREEN}$SCRIPT_DIR${RESET}"
    echo -e "${BLUE}=========================================================${RESET}"
    echo -e "${GREEN}                      功能菜单${RESET}"
    echo "---------------------------------------------------------"
    printf "%-4s | %-18s | %s\n" "序号" "目录名称" "目录描述"
    echo "---------------------------------------------------------"

    local index=1
    DIR_LIST=()

    while IFS= read -r dir; do
        dir_name=$(basename "$dir")
        if [ "$dir_name" = "common" ] || [ "$dir_name" = "log" ]; then
            continue
        fi
        DIR_LIST+=("$dir")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d | sort | grep -v "^$SCRIPT_DIR$")

    for dir in "${DIR_LIST[@]}"; do
        dir_name=$(basename "$dir")
        desc=$(get_dir_desc "$dir_name")
        desc=${desc:-"未配置描述"}
        printf "%-4s | ${GREEN}%-18s${RESET} | %s\n" "$index" "$dir_name" "$desc"
        ((index++))
    done

    echo "---------------------------------------------------------"
    echo "0  | 退出脚本"
    echo "---------------------------------------------------------"
}

# ===================== 文件菜单 & 智能执行 =====================
show_file_menu() {
    local target_dir="$1"
    local dir_name=$(basename "$target_dir")

    clear
    echo -e "${GREEN}===== 目录【${dir_name}】文件列表 =====${RESET}"
    echo "路径：$target_dir"
    echo "-----------------------------------------------------------------------------"
    printf "%-4s | %-25s | %-15s | %s\n" "序号" "文件名称" "文件类型" "文件描述"
    echo "-----------------------------------------------------------------------------"

    local index=1
    FILE_LIST=()

    while IFS= read -r file; do
        if [ -f "$file" ]; then
            file_name=$(basename "$file")
            FILE_LIST+=("$file")
            
            ext="${file_name##*.}"
            type_txt="其他文件"
            case "$ext" in
                sh) type_txt="Shell脚本" ;;
                jar) type_txt="Jar包" ;;
                sql) type_txt="SQL脚本" ;;
                md) type_txt="Markdown文档" ;;  # 新增md文件类型
            esac
            
            desc=$(get_file_desc "$file_name")
            desc=${desc:-"未配置描述"}
            printf "%-4s | %-25s | ${BLUE}%-15s${RESET} | %s\n" "$index" "$file_name" "$type_txt" "$desc"
            ((index++))
        fi
    done < <(find "$target_dir" -maxdepth 1 -type f | sort)

    if [ ${#FILE_LIST[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠ 该目录下无可用文件${RESET}"
        read -p "按回车返回主菜单..."
        return
    fi

    echo "-----------------------------------------------------------------------------"
    echo "0  | 返回主菜单"
    echo "-----------------------------------------------------------------------------"

    read -p "请选择要执行的文件序号：" file_idx
    if ! [[ "$file_idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 请输入有效数字！${RESET}"
        read -p "按回车继续..."
        return
    fi
    if [ "$file_idx" -eq 0 ]; then return; fi
    if [ "$file_idx" -lt 1 ] || [ "$file_idx" -gt ${#FILE_LIST[@]} ]; then
        echo -e "${RED}❌ 序号超出范围！${RESET}"
        read -p "按回车继续..."
        return
    fi

    local selected_file=${FILE_LIST[$((file_idx - 1))]}
    local fname=$(basename "$selected_file")
    local fext="${fname##*.}"

    echo -e "\n${GREEN}▶ 执行：$fname${RESET}"
    echo "----------------------------------------"

    case "$fext" in
        sh)
            chmod +x "$selected_file"
            "$selected_file"
            ;;

        jar)
            if command -v java &>/dev/null; then
                java -jar "$selected_file"
            else
                echo -e "${RED}❌ 未找到java命令${RESET}"
            fi
            ;;

        sql)
            if ! load_sql_command; then
                echo -e "${RED}❌ SQL_EXEC_CMD 未配置${RESET}"
            else

                temp_sql="${SCRIPT_DIR}/.tmp_sql_$(date +%s%N).sql"
                cp "$selected_file" "$temp_sql"
                chmod 644 "$temp_sql"

                vars=$(grep -o '&\{1,2\}[a-zA-Z0-9_]*' "$selected_file" | sed -e 's/^&//g' -e 's/^&//g' | sort -u)

                if [ -n "$vars" ]; then
                    echo -e "${BLUE}ℹ 检测到变量（支持 &变量 &&变量）：${RESET}"
                    echo "$vars" | tr ' ' '\n'
                    echo "----------------------------------------"

                    for v in $vars; do
                        read -p "请输入 $v 的值：" val
                        sed -i "s/&&$v/$val/g" "$temp_sql"
                        sed -i "s/&$v/$val/g" "$temp_sql"
                    done

                    echo -e "\n${BLUE}ℹ 变量替换完成，开始执行SQL...${RESET}"
                fi

                eval "${SQL_EXEC_CMD} ${temp_sql}"

                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✅ SQL执行成功！${RESET}"
                else
                    echo -e "${RED}❌ SQL执行失败！${RESET}"
                fi

                rm -f "$temp_sql"
            fi
            ;;
        
        # 新增：支持查看 md 文件
        md)
            echo -e "${YELLOW}📄 查看 Markdown 文件内容：${RESET}"
            echo "============================================================="
            cat "$selected_file"
            echo -e "\n============================================================="
            ;;

        *)
            echo -e "${YELLOW}⚠ 不支持该文件类型${RESET}"
            ;;
    esac

    echo "----------------------------------------"
    read -p "按回车返回菜单..."
}

# ===================== 主程序 =====================
check_config

while true; do
    show_main_menu
    if [ ${#DIR_LIST[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠ 无可用目录${RESET}"
        read -p "按回车退出..."
        exit 0
    fi

    read -p "请选择目录序号：" dir_idx
    if ! [[ "$dir_idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}❌ 请输入数字${RESET}"
        read -p "按回车继续..."
        continue
    fi
    if [ "$dir_idx" -eq 0 ]; then
        echo -e "${GREEN}👋 退出脚本${RESET}"
        exit 0
    fi
    if [ "$dir_idx" -lt 1 ] || [ "$dir_idx" -gt ${#DIR_LIST[@]} ]; then
        echo -e "${RED}❌ 无效序号${RESET}"
        read -p "按回车继续..."
        continue
    fi

    show_file_menu "${DIR_LIST[$((dir_idx - 1))]}"
done
